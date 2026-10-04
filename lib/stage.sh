# shellcheck shell=bash
# trinity stage — prepare and prove a candidate WITHOUT touching production.
#
# 1. Extracts the candidate commit with `git archive` (production checkout,
#    refs and working tree are not modified).
# 2. Fresh-chain proof: scratch PostgreSQL, full migration chain, exact ledger.
# 3. Upgrade proof: latest proven backup restored into a second scratch
#    database, only the pending migrations applied, ledger verified.
# 4. Provisioning proof: grant profiles of fresh vs upgraded scratch compared
#    (and against production's exported profile when supplied).
# 5. Activation plan: services/schema the candidate changes. Nothing is applied.

stage_usage() {
  cat <<'EOF'
Usage: trinity stage --ref SHA [--provisioning FILE] [--backup DIR] [--fetch]

  --ref SHA            candidate commit (must exist in the installed checkout's repo)
  --fetch              fetch the ref from origin first (adds objects only)
  --provisioning FILE  production profile (trinity provisioning export) to apply
                       to the fresh chain and compare against
  --backup DIR         backup to use for the upgrade proof (default: latest)

All databases are disposable, network-less containers on tmpfs. Production
containers, volumes, checkout and Edge are not modified.
EOF
}

_scratch_pg() {
  # _scratch_pg NAME -> starts a disposable PostgreSQL; registers cleanup.
  local name="$1" pw ready=false i
  pw="$(openssl rand -hex 24)"
  dk run -d --name "$name" --network none --memory 2g --pids-limit 256 \
    --tmpfs /var/lib/postgresql/data:rw,size=4g \
    -e POSTGRES_USER=blackwell -e POSTGRES_DB=blackwell -e POSTGRES_PASSWORD="$pw" \
    "$TRINITY_POSTGRES_IMAGE" >/dev/null
  on_exit "dk rm -f '$name' >/dev/null 2>&1 || true"
  for i in $(seq 1 60); do
    if dk exec "$name" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -X -U blackwell -d blackwell -Atqc "SELECT 1"' >/dev/null 2>&1; then
      ready=true; break
    fi
    sleep 1
  done
  [[ "$ready" == true ]] || die "scratch PostgreSQL $name did not become ready"
  dk exec "$name" psql -X -q -U blackwell -d blackwell -c 'CREATE EXTENSION IF NOT EXISTS vector' >/dev/null
}

_scratch_sql() { local name="$1"; shift; dk exec -i "$name" psql -X -q -v ON_ERROR_STOP=1 -U blackwell -d blackwell "$@"; }
_scratch_query() { dk exec "$1" psql -X -At -v ON_ERROR_STOP=1 -U blackwell -d blackwell -c "$2"; }

_scratch_external_roles() {
  _scratch_sql "$1" <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'blackwell_admin') THEN
    CREATE ROLE blackwell_admin NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'blackwell_runtime') THEN
    CREATE ROLE blackwell_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOBYPASSRLS;
  END IF;
END $$;
SQL
}

_scratch_profile() {
  # Same SQL as `provisioning export`, run against a scratch database.
  local name="$1" out="$2"
  {
    echo "BEGIN;"
    _scratch_query "$name" "$(_provisioning_sql '^blackwell_')"
    echo "COMMIT;"
  } >"$out"
}

_stage_affected() {
  # Maps changed paths between production HEAD and the candidate to services.
  local from="$1" to="$2" f
  git_root diff --name-only "$from" "$to" 2>/dev/null | while IFS= read -r f; do
    case "$f" in
      edge/*|apps/edge/*) echo "EDGE-PROTECTED $f" ;;
      apps/web/*) echo "web $f" ;;
      apps/vox/*) echo "vox $f" ;;
      apps/codex_bridge/*) echo "codex_bridge $f" ;;
      apps/operator_auth/*) echo "operator-services $f" ;;
      apps/*/*) echo "${f#apps/}" | awk -F/ -v p="$f" '{print $1" "p}' ;;
      src/*|policies/*) echo "python-services $f" ;;
      database/migrations/*) echo "schema $f" ;;
      compose*.yaml) echo "compose-definition $f" ;;
      *) echo "non-runtime $f" ;;
    esac
  done
}

stage_run() {
  local ref="" provisioning="" bdir="" fetch=0
  while (($#)); do
    case "$1" in
      --ref) ref="$2"; shift ;;
      --provisioning) provisioning="$(readlink -f "$2")"; shift ;;
      --backup) bdir="$(readlink -f "$2")"; shift ;;
      --fetch) fetch=1 ;;
      -h|--help) stage_usage; return 0 ;;
      *) die "stage: unknown option $1" ;;
    esac
    shift
  done
  [[ -n "$ref" ]] || die "stage requires --ref SHA"
  [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]] || die "--ref must be a commit SHA (branch names are not exact)"
  [[ -d "$TRINITY_ROOT/.git" ]] || die "no checkout at $TRINITY_ROOT"
  ((fetch)) && git_root fetch --quiet origin "$ref"
  local sha; sha="$(git_root rev-parse --verify "${ref}^{commit}" 2>/dev/null)" || die "commit $ref not in $TRINITY_ROOT (use --fetch)"
  acquire_lock
  fence_begin

  local dir src stamp
  stamp="$(utc_stamp)"
  dir="$TRINITY_STATE_DIR/stage/${sha:0:12}-${stamp}"
  umask 077; mkdir -p "$dir/source"
  src="$dir/source"
  git_root archive --format=tar "$sha" | tar -C "$src" -xf -
  ok "candidate $sha extracted (no change to the production checkout)"

  local prod_head; prod_head="$(git_root rev-parse HEAD)"
  _stage_affected "$prod_head" "$sha" >"$dir/affected.txt"

  # ---- fresh chain -----------------------------------------------------------
  local tag; tag="$(tr 'A-Z' 'a-z' <<<"$stamp")"
  local fresh="trinity-stage-fresh-$tag" m n=0
  _scratch_pg "$fresh"
  _scratch_external_roles "$fresh"
  for m in "$src"/database/migrations/*.sql; do
    _scratch_sql "$fresh" <"$m" >>"$dir/fresh-chain.log" 2>&1 || die "fresh chain failed at $(basename "$m") (see fresh-chain.log)"
    n=$((n + 1))
  done
  _scratch_query "$fresh" "SELECT version FROM blackwell.schema_migrations ORDER BY version" >"$dir/fresh-ledger.txt"
  "$PYTHON" "$HELPER" migrations --migrations-dir "$src/database/migrations" --ledger "$dir/fresh-ledger.txt" >"$dir/fresh-migrations.json"
  "$PYTHON" -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["ledger_matches_source_exactly"] else 1)' "$dir/fresh-migrations.json" \
    || die "fresh chain ledger does not match the candidate's migration files"
  ok "fresh chain: $n files, $(wc -l <"$dir/fresh-ledger.txt" | tr -d ' ') ledger rows, latest $(tail -1 "$dir/fresh-ledger.txt")"
  if [[ -n "$provisioning" ]]; then
    _scratch_sql "$fresh" <"$provisioning" >>"$dir/fresh-chain.log" 2>&1 || die "production provisioning profile does not apply cleanly to the candidate schema"
    ok "production provisioning profile applies to the candidate schema"
  fi
  _scratch_profile "$fresh" "$dir/profile-fresh.sql"

  # ---- upgrade from the latest proven backup ------------------------------------
  if [[ -z "$bdir" && -d "$TRINITY_STATE_DIR/backups" ]]; then
    bdir="$(find "$TRINITY_STATE_DIR/backups" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort | tail -1)"
  fi
  local upgrade_result="NOT_RUN (no backup available; run: trinity backup)"
  if [[ -n "$bdir" && -f "$bdir/db/database.dump" ]]; then
    verify_checksums "$bdir"
    local up="trinity-stage-upgrade-$tag"
    _scratch_pg "$up"
    _restore_roles "$up" "$bdir/db/roles.sql" blackwell
    dk exec -i "$up" pg_restore -U blackwell -d blackwell --exit-on-error <"$bdir/db/database.dump" >"$dir/upgrade-restore.log" 2>&1 \
      || die "backup did not restore into scratch (see upgrade-restore.log)"
    local current_max; current_max="$(tail -1 "$bdir/db/ledger.txt")"
    : >"$dir/upgrade-applied.txt"
    for m in "$src"/database/migrations/*.sql; do
      local v; v="$(basename "$m")"; v="${v:0:4}"
      [[ "$v" > "$current_max" ]] || continue
      _scratch_sql "$up" <"$m" >>"$dir/upgrade.log" 2>&1 || die "upgrade failed at $(basename "$m") (see upgrade.log)"
      basename "$m" >>"$dir/upgrade-applied.txt"
    done
    _scratch_query "$up" "SELECT version FROM blackwell.schema_migrations ORDER BY version" >"$dir/upgrade-ledger.txt"
    if cmp -s "$dir/upgrade-ledger.txt" "$dir/fresh-ledger.txt"; then
      upgrade_result="PASS from ledger $current_max, applied $(wc -l <"$dir/upgrade-applied.txt" | tr -d ' ') file(s)"
    else
      upgrade_result="FAIL ledger after upgrade differs from fresh chain"
    fi
    _scratch_profile "$up" "$dir/profile-upgrade.sql"
    if diff "$dir/profile-fresh.sql" "$dir/profile-upgrade.sql" >"$dir/profile-fresh-vs-upgrade.diff"; then
      echo "IDENTICAL" >"$dir/provisioning-result.txt"
    else
      echo "DIFFERS (see profile-fresh-vs-upgrade.diff)" >"$dir/provisioning-result.txt"
    fi
    ok "upgrade proof: $upgrade_result; provisioning fresh vs upgrade: $(cat "$dir/provisioning-result.txt")"
  else
    warn "upgrade proof skipped: $upgrade_result"
  fi
  if [[ -n "$provisioning" ]]; then
    diff <(grep -v '^--' "$provisioning") "$dir/profile-fresh.sql" >"$dir/profile-production-vs-candidate.diff" || true
  fi

  fence_assert_unchanged
  {
    echo "# Trinity stage report"
    echo
    echo "- generated: $(utc_iso) on $(hostname)"
    echo "- production HEAD: \`$prod_head\`"
    echo "- candidate: \`$sha\`"
    echo "- fresh chain: $n migration files, $(wc -l <"$dir/fresh-ledger.txt" | tr -d ' ') ledger rows, latest $(tail -1 "$dir/fresh-ledger.txt")"
    echo "- upgrade proof: $upgrade_result"
    echo "- provisioning fresh vs upgrade: $(cat "$dir/provisioning-result.txt" 2>/dev/null || echo n/a)"
    echo "- production profile supplied: ${provisioning:-no}"
    echo
    echo "## What activation would change (not performed)"
    echo
    if [[ -s "$dir/affected.txt" ]]; then
      awk '{print $1}' "$dir/affected.txt" | sort | uniq -c | awk '{printf "- %s (%s files)\n", $2, $1}'
    else
      echo "- nothing: candidate equals production HEAD"
    fi
    grep -q '^EDGE-PROTECTED' "$dir/affected.txt" && echo && echo "**Edge files change. Edge is protected; this candidate needs Jimmy's explicit Edge decision.**"
    echo
    echo "Pending migrations for production (from backup ledger):"
    if [[ -s "$dir/upgrade-applied.txt" ]]; then sed 's/^/- /' "$dir/upgrade-applied.txt"; else echo "- none / unknown"; fi
    echo
    echo "Production was not modified. Edge unchanged. Activation requires the owner's decision."
  } >"$dir/REPORT.md"
  write_checksums "$dir"
  ok "stage report: $dir/REPORT.md"
  printf '%s\n' "$dir"
}
