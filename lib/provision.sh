# shellcheck shell=bash
# trinity provisioning — capture the exact runtime privilege shape as reviewable SQL.
#
# Historical runtime grants (e.g. blackwell_runtime core-table privileges) were
# applied operationally and are not fully represented in migrations. This turns
# the installed system's actual grants into an idempotent, secret-free SQL
# profile that a fresh install or a scratch proof can replay, so provisioning
# becomes source-complete instead of a manual fixture.

provisioning_usage() {
  cat <<'EOF'
Usage: trinity provisioning export [--out FILE] [--roles REGEX]
       trinity provisioning compare FILE_A FILE_B

export   Read-only. Emits GRANT/role-attribute SQL for service roles
         (default regex: ^blackwell_) as installed now. No passwords.
compare  Diff two exported profiles (e.g. production vs a fresh install).
EOF
}

_provisioning_sql() {
  local re="$1"
  # Each row is already a complete, idempotent SQL statement.
  cat <<SQL
WITH roles AS (
  SELECT oid, rolname FROM pg_roles WHERE rolname ~ '${re}' AND NOT rolsuper
)
SELECT stmt FROM (
  SELECT 1 AS o, r.rolname AS k,
    format('DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %L) THEN CREATE ROLE %I; END IF; END \$\$;', r.rolname, r.rolname) AS stmt
  FROM roles r
  UNION ALL
  SELECT 2, a.rolname,
    format('ALTER ROLE %I %s %s %s %s %s;', a.rolname,
      CASE WHEN a.rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END,
      CASE WHEN a.rolinherit THEN 'INHERIT' ELSE 'NOINHERIT' END,
      'NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
      CASE WHEN a.rolbypassrls THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END,
      CASE WHEN a.rolconnlimit >= 0 THEN 'CONNECTION LIMIT ' || a.rolconnlimit ELSE '' END)
  FROM pg_roles a JOIN roles r ON r.oid = a.oid
  UNION ALL
  SELECT 3, g.rolname || m.rolname, format('GRANT %I TO %I;', g.rolname, m.rolname)
  FROM pg_auth_members am JOIN pg_roles g ON g.oid = am.roleid JOIN roles m ON m.oid = am.member
  UNION ALL
  SELECT 4, n.nspname || r.rolname, format('GRANT %s ON SCHEMA %I TO %I;', a.privilege_type, n.nspname, r.rolname)
  FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a JOIN roles r ON r.oid = a.grantee
  UNION ALL
  SELECT 5, n.nspname || c.relname || r.rolname || a.privilege_type,
    format('GRANT %s ON %s %I.%I TO %I;', a.privilege_type,
      CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, n.nspname, c.relname, r.rolname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN roles r ON r.oid = a.grantee
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  UNION ALL
  SELECT 6, n.nspname || c.relname || at.attname || r.rolname || a.privilege_type,
    format('GRANT %s (%I) ON TABLE %I.%I TO %I;', a.privilege_type, at.attname, n.nspname, c.relname, r.rolname)
  FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(at.attacl) a JOIN roles r ON r.oid = a.grantee
  WHERE at.attacl IS NOT NULL AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  UNION ALL
  SELECT 7, n.nspname || p.proname || r.rolname,
    format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO %I;', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), r.rolname)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(p.proacl) a JOIN roles r ON r.oid = a.grantee
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
) s
ORDER BY o, k, stmt
SQL
}

provisioning_export() {
  local out="" re='^blackwell_'
  while (($#)); do
    case "$1" in
      --out) out="$2"; shift ;;
      --roles) re="$2"; shift ;;
      *) die "provisioning export: unknown option $1" ;;
    esac
    shift
  done
  [[ "$re" =~ ^[A-Za-z0-9_^$.|()*+?-]+$ ]] || die "--roles must be a simple regular expression"
  container_running "$TRINITY_DB_CONTAINER" || die "database container is not running"
  [[ -n "$out" ]] || out="$(new_run_dir provisioning)/runtime-provisioning.sql"
  local ledger
  ledger="$(_db_exec_ro "SELECT max(version) FROM blackwell.schema_migrations" 2>/dev/null || echo unknown)"
  {
    echo "-- Trinity runtime provisioning profile"
    echo "-- exported $(utc_iso) from $(hostname) at ledger ${ledger}; role regex: ${re}"
    echo "-- Idempotent. Contains no passwords; LOGIN roles receive passwords separately."
    echo "BEGIN;"
    _db_exec_ro "$(_provisioning_sql "$re")"
    echo "COMMIT;"
  } >"$out"
  scan_secrets_or_die "$out"
  ok "provisioning profile: $out ($(grep -c '^GRANT' "$out") grants)"
  printf '%s\n' "$out"
}

provisioning_compare() {
  local a="$1" b="$2"
  [[ -f "$a" && -f "$b" ]] || die "provisioning compare FILE_A FILE_B"
  if diff <(grep -v '^--' "$a") <(grep -v '^--' "$b"); then
    ok "profiles are identical"
  else
    warn "profiles differ (< only in $a, > only in $b)"
    return 1
  fi
}

provisioning_main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    export)  provisioning_export "$@" ;;
    compare) provisioning_compare "$@" ;;
    ""|-h|--help|help) provisioning_usage ;;
    *) die "provisioning: unknown command $sub" ;;
  esac
}
