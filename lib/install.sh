# shellcheck shell=bash
# trinity install — fresh or recovery installation on a host WITHOUT Trinity.
#
# It refuses to run where any Trinity installation exists. Existing hosts use
# `trinity protect` (discover + preserve UI + proven backup) instead. Bootstrap
# is never re-run over an installation.

install_usage() {
  cat <<'EOF'
Usage: sudo trinity install [options]

Fresh install (new host):
  --ref SHA            source commit to install (default: pinned continuation commit)
  --repo URL           source repository (default: the-black-well on GitHub)
  --provisioning FILE  runtime grant profile from `trinity provisioning export`
                       on the existing system (required to start runtime services)
  --domain NAME        public domain for Edge/operator origin (default: theblackwell.online)

Recovery install (rebuild from a `trinity backup` bundle):
  --from-backup DIR    restore source (bundle + uncommitted work), data/ and database
  --secrets-tar FILE   decrypted tar from `trinity backup secrets`; production
                       DSNs/tokens are reused and role passwords re-applied from them

Common:
  --no-start           stop after schema/provisioning proof (no services started)
  --yes                skip the typed confirmation

What is never automated: model OAuth login, DNS, Telegram tokens, any change to an
existing installation, any start of Edge on a host where an Edge already exists.
EOF
}

# Service DSN files -> database role. Derived from compose.yaml variable names;
# verify against `discover` (db-sessions) on the existing system.
INSTALL_ROLE_FILES=(
  "blackwell_runtime:@ROOT@/secrets/blackwell_database_url:0644:root"
  "blackwell_operator_auth:/etc/blackwell/operator-auth-database-url:0640:10001"
  "blackwell_admission_authorizer:/etc/blackwell/admission-authorizer-database-url:0640:10001"
  "blackwell_admission_executor:/etc/blackwell/admission-executor-database-url:0640:10001"
  "blackwell_operator_admission_requester:/etc/blackwell/operator-admission-requester-database-url:0640:10001"
)
INSTALL_TOKEN_FILES=(
  /etc/blackwell/operator-auth-internal-token
  /etc/blackwell/admission-authorizer-internal-token
  /etc/blackwell/admission-executor-internal-token
)
INSTALL_START_ORDER=(api embedder vox codex_bridge worker dispatcher repository_ingestor
  operator-auth admission-authorizer admission-executor operator-admission-broker web)

install_detect_existing() {
  # Prints reasons an installation exists; empty output means a clean host.
  [[ -e "$TRINITY_ROOT" && -n "$(ls -A "$TRINITY_ROOT" 2>/dev/null)" ]] && echo "checkout present at $TRINITY_ROOT"
  if command -v docker >/dev/null 2>&1 && docker_init 2>/dev/null; then
    local c v
    c="$(dk ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^blackwell-' | tr '\n' ' ')"
    [[ -n "$c" ]] && echo "containers present: $c"
    v="$(dk volume ls -q 2>/dev/null | grep -E '^blackwell_postgres_data$' || true)"
    [[ -n "$v" ]] && echo "database volume present: $v"
  fi
  [[ -d /etc/blackwell && -n "$(ls -A /etc/blackwell 2>/dev/null)" ]] && echo "/etc/blackwell is populated"
  return 0
}

_rand() { openssl rand -hex "${1:-32}"; }

# TRINITY_INSTALL_SKIP="svc ..." defers services (staged bring-up, or a service
# whose build dependency is unavailable). Skipped services are reported, never hidden.
_install_skipped() { [[ " ${TRINITY_INSTALL_SKIP:-} " == *" $1 "* ]]; }

_write_secret() {
  # _write_secret PATH MODE GROUP  (content on stdin; never echoed)
  local path="$1" mode="$2" group="$3"
  [[ -d "$(dirname "$path")" ]] || install -d -m 0700 "$(dirname "$path")"
  ( umask 077; cat >"$path" )
  chown "root:$group" "$path"
  chmod "$mode" "$path"
}

_psql_admin() {
  # SQL on stdin, executed as the bootstrap owner over the container socket.
  dk exec -i "$TRINITY_DB_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U blackwell -d blackwell
}

_wait_healthy() {
  local c="$1" tries="${2:-90}" s i
  for ((i = 0; i < tries; i++)); do
    s="$(dk container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}-nohealthcheck{{end}}' "$c" 2>/dev/null || echo missing)"
    case "$s" in healthy|running-nohealthcheck) return 0 ;; unhealthy|exited*|dead*) return 1 ;; esac
    sleep 2
  done
  return 1
}

_install_source_fresh() {
  local repo="$1" ref="$2"
  log "cloning $repo"
  git clone --quiet "$repo" "$TRINITY_ROOT"
  git_root fetch --quiet origin "$ref" 2>/dev/null || true
  git_root checkout --quiet --detach "$ref"
  local head; head="$(git_root rev-parse HEAD)"
  [[ "$head" == "$ref"* ]] || die "checked out $head, expected $ref"
  ok "source at $head"
}

_install_source_from_backup() {
  local bdir="$1" head
  local bundle="$bdir/source/repo-0.bundle"
  [[ -f "$bundle" ]] || die "no source/repo-0.bundle in $bdir"
  head="$(cat "$bdir/source/repo-0.head")"
  git clone --quiet "$bundle" "$TRINITY_ROOT"
  git_root checkout --quiet --detach "$head"
  if [[ -f "$bdir/source/repo-0.work.tar" ]]; then
    tar -C "$TRINITY_ROOT" -xf "$bdir/source/repo-0.work.tar"
    ok "uncommitted/untracked work restored ($(wc -l <"$bdir/source/repo-0.work.txt" | tr -d ' ') files)"
  fi
  if [[ -f "$bdir/data/data.tar" ]]; then
    tar -C "$TRINITY_ROOT" -xf "$bdir/data/data.tar"
    ok "data/ restored"
  fi
  ok "source restored at $head"
}

_install_normalize_modes() {
  # Builder rule 19: source must be readable by the non-root runtime UIDs.
  chmod 755 "$TRINITY_ROOT"
  find "$TRINITY_ROOT" -path "$TRINITY_ROOT/secrets" -prune -o -path "$TRINITY_ROOT/.git" -prune -o \
    -type d -exec chmod u+rwx,go+rx {} + -o -type f -exec chmod go+r {} +
}

_install_generate_secrets() {
  local domain="$1" spec role path fmode group pw
  install -d -m 0700 "$TRINITY_ROOT/secrets"
  install -d -m 0750 -g 10001 /etc/blackwell
  _rand 32 | tr -d '\n' | _write_secret "$TRINITY_ROOT/secrets/blackwell_db_password" 0644 root
  for spec in "${INSTALL_ROLE_FILES[@]}"; do
    IFS=: read -r role path fmode group <<<"${spec//@ROOT@/$TRINITY_ROOT}"
    pw="$(_rand 24)"
    printf 'postgresql://%s:%s@postgres:5432/blackwell' "$role" "$pw" | _write_secret "$path" "$fmode" "$group"
  done
  for path in "${INSTALL_TOKEN_FILES[@]}"; do
    _rand 32 | tr -d '\n' | _write_secret "$path" 0640 10001
  done
  ( umask 077
    cat >"$TRINITY_ROOT/.env" <<EOF
POSTGRES_DB=blackwell
POSTGRES_USER=blackwell
BLACKWELL_MIND_ENABLED=true
BLACKWELL_MIND_PROVIDER=blackwell
BLACKWELL_MIND_MODEL=mock-strategist-v1
BLACKWELL_MIND_AUTH_MODE=NONE
EOF
  )
  [[ "$domain" == "theblackwell.online" ]] || warn "custom domain: update edge/caddy/Caddyfile and BLACKWELL_OPERATOR_HOST/ORIGIN in compose.yaml"
  ok "secrets generated (values not displayed)"
}

_install_restore_secrets() {
  local tarfile="$1"
  tar -tPf "$tarfile" >/dev/null || die "cannot read $tarfile"
  tar -xPf "$tarfile"
  ok "production secrets restored from $(basename "$tarfile")"
}

_install_edge_auth() {
  # Site-wide HTTP basic auth in front of the Cathedral (auth.caddy is imported by the Caddyfile).
  local file="$TRINITY_ROOT/edge/caddy/auth.caddy" creds="$1"
  [[ -f "$file" ]] && return 0
  local pw hash
  pw="$(_rand 18)"
  hash="$(printf '%s\n%s\n' "$pw" "$pw" | dk run --rm -i --network none caddy:2-alpine caddy hash-password 2>/dev/null | tail -1)"
  [[ "$hash" == \$2* ]] || die "could not hash the Edge password"
  ( umask 077; printf 'basic_auth {\n    trinity %s\n}\n' "$hash" >"$file" )
  chmod 0644 "$file"
  printf 'Edge (browser) login: user=trinity password=%s\n' "$pw" >>"$creds"
}

_install_db() {
  local mode="$1" bdir="$2" provisioning="$3" creds="$4"
  compose_safe up -d --no-deps postgres
  _wait_healthy "$TRINITY_DB_CONTAINER" 60 || die "postgres did not become healthy"
  ok "postgres healthy"

  if [[ "$mode" == restore ]]; then
    _restore_roles "$TRINITY_DB_CONTAINER" "$bdir/db/roles.sql" blackwell
    dk exec -i "$TRINITY_DB_CONTAINER" pg_restore -U blackwell -d blackwell --exit-on-error <"$bdir/db/database.dump" \
      || die "database restore failed"
    dk exec "$TRINITY_DB_CONTAINER" psql -X -At -U blackwell -d blackwell -c "SELECT version FROM blackwell.schema_migrations ORDER BY version" >"$TRINITY_STATE_DIR/install-ledger.txt"
    cmp -s "$bdir/db/ledger.txt" "$TRINITY_STATE_DIR/install-ledger.txt" || die "restored ledger differs from the backup ledger"
    ok "database restored; ledger matches backup ($(wc -l <"$bdir/db/ledger.txt" | tr -d ' ') rows)"
  else
    # External roles the historical migrations expect (TRINITY-BUILDER-RULES §14).
    _psql_admin <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'blackwell_admin') THEN
    CREATE ROLE blackwell_admin NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'blackwell_runtime') THEN
    CREATE ROLE blackwell_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOBYPASSRLS;
  END IF;
END $$;
SQL
    local m n=0
    for m in "$TRINITY_ROOT"/database/migrations/*.sql; do
      _psql_admin <"$m" >>"$TRINITY_STATE_DIR/install-migrations.log" 2>&1 || die "migration $(basename "$m") failed (see install-migrations.log)"
      n=$((n + 1))
    done
    dk exec "$TRINITY_DB_CONTAINER" psql -X -At -U blackwell -d blackwell -c "SELECT version FROM blackwell.schema_migrations ORDER BY version" >"$TRINITY_STATE_DIR/install-ledger.txt"
    "$PYTHON" "$HELPER" migrations --migrations-dir "$TRINITY_ROOT/database/migrations" --ledger "$TRINITY_STATE_DIR/install-ledger.txt" \
      | "$PYTHON" -c 'import json,sys; r=json.load(sys.stdin); sys.exit(0 if r["ledger_matches_source_exactly"] else 1)' \
      || die "ledger does not match source migrations after the full chain"
    ok "fresh migration chain: $n files, ledger $(wc -l <"$TRINITY_STATE_DIR/install-ledger.txt" | tr -d ' ') rows, latest $(tail -1 "$TRINITY_STATE_DIR/install-ledger.txt")"
    if [[ -n "$provisioning" ]]; then
      _psql_admin <"$provisioning" >/dev/null || die "provisioning profile failed"
      ok "runtime provisioning profile applied ($(grep -c '^GRANT' "$provisioning") grants)"
    else
      warn "no --provisioning profile: runtime core-table grants are not source-complete;"
      warn "runtime services will not be started (export one with: trinity provisioning export)"
      INSTALL_NO_RUNTIME=1
    fi
  fi

  # LOGIN + password for each service role, taken from its DSN file (never echoed).
  local spec role path fmode group dsn pw
  for spec in "${INSTALL_ROLE_FILES[@]}"; do
    IFS=: read -r role path fmode group <<<"${spec//@ROOT@/$TRINITY_ROOT}"
    [[ -f "$path" ]] || { warn "missing $path; $role left NOLOGIN"; continue; }
    dsn="$(cat "$path")"
    [[ "$dsn" =~ ^postgres(ql)?://([^:]+):([^@]+)@ ]] || die "unexpected DSN format in $path"
    [[ "${BASH_REMATCH[2]}" == "$role" ]] || warn "$path authenticates as ${BASH_REMATCH[2]} (expected $role); using the file's role"
    role="${BASH_REMATCH[2]}"; pw="${BASH_REMATCH[3]}"
    printf "ALTER ROLE %s LOGIN PASSWORD '%s';\n" "$role" "${pw//\'/\'\'}" | _psql_admin >/dev/null || die "could not activate $role"
  done
  unset dsn pw
  ok "service roles activated with file-backed passwords"

  if [[ "$mode" == fresh ]]; then
    local opw; opw="$(_rand 16)"
    if printf "SELECT 1 FROM blackwell.bootstrap_runtime_operator_principal('sovereign', '%s', 'trinity-installer');\n" "$opw" \
      | _psql_admin >/dev/null; then
      printf 'Sovereign operator login: user=sovereign password=%s\n' "$opw" >>"$creds"
      ok "Sovereign operator 'sovereign' created"
    else
      warn "Sovereign operator bootstrap failed; create it later with blackwell.bootstrap_runtime_operator_principal"
    fi
    unset opw
  fi
}

install_run() {
  local repo="$TRINITY_SOURCE_REPO" ref="$TRINITY_SOURCE_REF" provisioning="" bdir="" secrets_tar="" start=1 domain="$TRINITY_DOMAIN"
  while (($#)); do
    case "$1" in
      --repo) repo="$2"; shift ;;
      --ref) ref="$2"; shift ;;
      --provisioning) provisioning="$(readlink -f "$2")"; shift ;;
      --from-backup) bdir="$(readlink -f "$2")"; shift ;;
      --secrets-tar) secrets_tar="$(readlink -f "$2")"; shift ;;
      --domain) domain="$2"; shift ;;
      --no-start) start=0 ;;
      --yes) TRINITY_ASSUME_YES=1 ;;
      -h|--help) install_usage; return 0 ;;
      *) die "install: unknown option $1" ;;
    esac
    shift
  done
  require_root
  require_cmd git openssl tar sha256sum "$PYTHON"
  docker_init
  dk compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"

  local existing; existing="$(install_detect_existing)"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing" | sed 's/^/  - /' >&2
    die "an installation already exists; install never runs over it. Use: trinity protect"
  fi

  local mode=fresh
  if [[ -n "$bdir" ]]; then
    mode=restore
    verify_checksums "$bdir"
    [[ -f "$bdir/db/database.dump" ]] || die "backup has no database dump"
    [[ "$(cat "$bdir/db/restore-proof-result.txt" 2>/dev/null)" == PASS* ]] || warn "this backup's restore proof did not PASS"
  fi
  [[ -z "$provisioning" || -f "$provisioning" ]] || die "provisioning file not found"

  confirm_phrase "INSTALL TRINITY" "This performs a ${mode^^} installation into $TRINITY_ROOT on $(hostname)."
  umask 022
  getent passwd "$TRINITY_MAINT_USER" >/dev/null || { useradd -m -s /bin/bash "$TRINITY_MAINT_USER"; ok "created maintenance user $TRINITY_MAINT_USER"; }
  mkdir -p "$TRINITY_STATE_DIR"
  local creds=/root/trinity-initial-credentials.txt
  ( umask 077; : >>"$creds" )

  if [[ "$mode" == restore ]]; then _install_source_from_backup "$bdir"; else _install_source_fresh "$repo" "$ref"; fi
  _install_normalize_modes

  if [[ -n "$secrets_tar" ]]; then _install_restore_secrets "$secrets_tar"; else _install_generate_secrets "$domain"; fi
  [[ "$mode" == restore && -z "$secrets_tar" ]] && warn "restore without --secrets-tar: new credentials generated; model OAuth must be re-linked"

  INSTALL_NO_RUNTIME=0
  [[ "$mode" == restore ]] && provisioning=""
  _install_db "$mode" "$bdir" "$provisioning" "$creds"

  if ((start == 0)) || ((INSTALL_NO_RUNTIME)); then
    ok "installation stopped after database proof (no services started)"
  else
    _install_edge_auth "$creds"
    log "building images one service at a time (this takes a while)"
    local svc built_failed=()
    for svc in "${INSTALL_START_ORDER[@]}" edge; do
      [[ "$svc" == vox ]] && continue   # prebuilt upstream image, pulled on start
      _install_skipped "$svc" && continue
      dk compose --project-directory "$TRINITY_ROOT" -p "$TRINITY_COMPOSE_PROJECT" build "$svc" \
        >>"$TRINITY_STATE_DIR/install-build.log" 2>&1 || built_failed+=("$svc")
    done
    ((${#built_failed[@]} == 0)) || die "image build failed for: ${built_failed[*]} (see $TRINITY_STATE_DIR/install-build.log); nothing was started"
    ok "all images built"
    local failed=()
    for svc in "${INSTALL_START_ORDER[@]}"; do
      _install_skipped "$svc" && { warn "NOT STARTED (skipped by TRINITY_INSTALL_SKIP): $svc"; continue; }
      compose_safe up -d --no-deps "$svc" || { failed+=("$svc"); continue; }
      _wait_healthy "blackwell-${svc//_/-}" 90 || failed+=("$svc")
    done
    # Edge: started only here, only because no Edge existed on this host.
    if container_exists "$TRINITY_EDGE_CONTAINER"; then
      warn "Edge already exists; not touched"
    else
      dk compose --project-directory "$TRINITY_ROOT" -p "$TRINITY_COMPOSE_PROJECT" up -d --no-deps edge || failed+=(edge)
    fi
    if ((${#failed[@]})); then
      warn "services not healthy: ${failed[*]} (see: docker logs <container>)"
    else
      ok "all services healthy"
    fi
  fi
  chmod 600 "$creds"
  ok "install complete ($mode)"
  if [[ -s "$creds" ]]; then
    log "initial credentials: $creds (root-only; move them to your password manager, then delete the file)"
  else
    rm -f "$creds"
  fi
  log "next: trinity protect   (baseline + UI snapshot + proven backup of the new install)"
}
