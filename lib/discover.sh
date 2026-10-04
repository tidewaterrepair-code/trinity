# shellcheck shell=bash
# trinity discover — read-only P0 baseline of the installed system.
#
# Collects source, runtime, schema, privilege, UI and exposure facts into a
# private run directory. It never writes to the database, containers, the
# checkout or Edge, and it never records secret values.

discover_usage() {
  cat <<'EOF'
Usage: trinity discover [--no-probe] [--out DIR]

Read-only baseline of the installed Trinity: checkouts and dirty work, Docker
runtime identity, Edge fence, served UI hashes vs source, migration ledger,
database role/privilege shape, secret file metadata and public exposure.

  --no-probe   skip the GET-only HTTPS probe of the public domain
  --out DIR    write into DIR instead of a new run directory
EOF
}

_db_exec_ro() {
  # Read-only SQL through the database container's local socket.
  # default_transaction_read_only makes any accidental write fail.
  local sql="$1" user db
  user="$(_db_env POSTGRES_USER)"; db="$(_db_env POSTGRES_DB)"
  [[ -n "$user" && -n "$db" ]] || return 1
  dk exec -e PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=30000' \
    "$TRINITY_DB_CONTAINER" psql -X -At -v ON_ERROR_STOP=1 -U "$user" -d "$db" -c "$sql"
}

_db_env() {
  # Only POSTGRES_USER / POSTGRES_DB are ever read from the container environment.
  local key="$1"
  case "$key" in POSTGRES_USER|POSTGRES_DB) ;; *) return 1 ;; esac
  dk container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$TRINITY_DB_CONTAINER" 2>/dev/null \
    | awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}'
}

_strip_userinfo() { sed -E 's#(://)[^/@[:space:]]+@#\1#g'; }

_discover_git_repo() {
  local path="$1" tmp="$2" spec sha label
  mkdir -p "$tmp"
  git_at "$path" rev-parse HEAD >"$tmp/head.txt" 2>/dev/null || return 1
  git_at "$path" symbolic-ref --short -q HEAD >"$tmp/branch.txt" 2>/dev/null || echo "(detached)" >"$tmp/branch.txt"
  git_at "$path" describe --tags --always --dirty >"$tmp/describe.txt" 2>/dev/null || true
  git_at "$path" remote -v 2>/dev/null | _strip_userinfo | sort -u >"$tmp/remotes.txt" || true
  git_at "$path" for-each-ref --format='%(objectname:short) %(refname)' refs/heads refs/remotes refs/tags >"$tmp/branches.txt" 2>/dev/null || true
  git_at "$path" worktree list >"$tmp/worktrees.txt" 2>/dev/null || true
  git_at "$path" stash list >"$tmp/stash.txt" 2>/dev/null || true
  git_at "$path" status --porcelain=v1 --untracked-files=no >"$tmp/dirty.txt" 2>/dev/null || true
  git_at "$path" ls-files --others --exclude-standard >"$tmp/untracked.txt" 2>/dev/null || true
  : >"$tmp/known.txt"
  for spec in "${TRINITY_KNOWN_COMMITS[@]}"; do
    sha="${spec%%:*}"; label="${spec#*:}@${sha:0:7}"
    if ! git_at "$path" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      echo "$label absent" >>"$tmp/known.txt"
    elif git_at "$path" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      echo "$label in_head" >>"$tmp/known.txt"
    else
      echo "$label present_not_in_head" >>"$tmp/known.txt"
    fi
  done
  "$PYTHON" "$HELPER" git-report --dir "$tmp" --path "$path"
}

_discover_checkouts() {
  # The installed checkout plus any maintenance worktrees/clones.
  local -a found=()
  [[ -e "$TRINITY_ROOT/.git" ]] && found+=("$TRINITY_ROOT")
  if [[ -d "$TRINITY_MAINT_HOME/trinity-maintenance" ]]; then
    while IFS= read -r -d '' g; do
      found+=("$(dirname "$g")")
    done < <(find "$TRINITY_MAINT_HOME/trinity-maintenance" -maxdepth 3 -name .git -print0 2>/dev/null)
  fi
  printf '%s\n' "${found[@]}" | awk 'NF && !seen[$0]++'
}

discover_run() {
  local out="" probe=1
  while (($#)); do
    case "$1" in
      --no-probe) probe=0 ;;
      --out) out="$2"; shift ;;
      -h|--help) discover_usage; return 0 ;;
      *) die "discover: unknown option $1" ;;
    esac
    shift
  done
  [[ -n "$out" ]] || out="$(new_run_dir discover)"
  mkdir -p "$out/raw" "$out/work"
  local raw="$out/raw" work="$out/work"
  log "discovery output: $out"

  # ---- host -------------------------------------------------------------
  local docker_ver compose_ver
  docker_ver="$(dk version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)"
  compose_ver="$(dk compose version --short 2>/dev/null || echo unavailable)"
  HOSTNAME_V="$(hostname)" OS_V="$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s)" \
  KERNEL_V="$(uname -r)" DOCKER_V="$docker_ver" COMPOSE_V="$compose_ver" \
  DISK_V="$(df -h / 2>/dev/null | awk 'NR==2{print $4" free of "$2}')" \
  MEM_V="$(free -h 2>/dev/null | awk '/^Mem:/{print $2" total, "$7" available"}')" \
  SSHD_V="$( (sshd -V 2>&1 || true) | head -1)" \
  "$PYTHON" - >"$raw/host.json" <<'PY'
import json, os
print(json.dumps({k.lower(): os.environ.get(v) for k, v in {
  "hostname": "HOSTNAME_V", "os": "OS_V", "kernel": "KERNEL_V", "docker": "DOCKER_V",
  "compose": "COMPOSE_V", "disk_free_root": "DISK_V", "memory": "MEM_V", "sshd": "SSHD_V"}.items()}, indent=2))
PY
  ok "host facts"

  # ---- source checkouts ------------------------------------------------------
  local i=0 repo
  {
    printf '[\n'
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      ((i > 0)) && printf ',\n'
      _discover_git_repo "$repo" "$work/git-$i" || printf '{"path": "%s", "error": "not a readable git checkout"}' "$repo"
      i=$((i + 1))
    done < <(_discover_checkouts)
    printf ']\n'
  } >"$raw/git.json"
  ok "source checkouts: $i"

  # ---- runtime ---------------------------------------------------------------
  local ids
  ids="$(dk ps -aq --filter "name=blackwell" 2>/dev/null || true)"
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    dk container inspect $ids | "$PYTHON" "$HELPER" sanitize-inspect >"$raw/containers.json"
  else
    echo '[]' >"$raw/containers.json"
  fi
  dk image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Digest}} {{.CreatedAt}}' 2>/dev/null \
    | grep -E 'blackwell|pgvector|caddy|kokoro|nginx' >"$raw/images.txt" || true
  dk volume ls --format '{{.Name}} {{.Driver}}' >"$raw/volumes.txt" 2>/dev/null || true
  dk network ls --format '{{.Name}} {{.Driver}} internal={{.Internal}}' >"$raw/networks.txt" 2>/dev/null || true
  ok "runtime containers/images/volumes/networks"

  # ---- Edge fence ------------------------------------------------------------
  local eid eimg estart estatus
  read -r eid eimg estart estatus <<<"$(edge_identity)"
  printf '{"fence": "%s", "id": "%s", "image": "%s", "started_at": "%s", "status": "%s", "golden_id": "%s", "golden_image": "%s"}\n' \
    "$(edge_fence_status)" "$eid" "${eimg:-}" "${estart:-}" "${estatus:-}" "$TRINITY_EDGE_GOLDEN_ID" "$TRINITY_EDGE_GOLDEN_IMAGE" >"$raw/edge.json"
  ok "Edge fence: $(edge_fence_status)"

  # ---- served UI vs source ----------------------------------------------------
  local served_count=0 served_bytes=0 web_image=""
  if container_running "$TRINITY_WEB_CONTAINER"; then
    web_image="$(dk container inspect -f '{{.Image}}' "$TRINITY_WEB_CONTAINER")"
    dk exec "$TRINITY_WEB_CONTAINER" sh -c "cd '$TRINITY_WEB_DOCROOT' && find . -type f -exec sha256sum {} +" \
      | sed 's#  \./#  #' | LC_ALL=C sort -k2 >"$out/served-ui.sha256"
    served_count="$(wc -l <"$out/served-ui.sha256" | tr -d ' ')"
    served_bytes="$(dk exec "$TRINITY_WEB_CONTAINER" sh -c "du -sb '$TRINITY_WEB_DOCROOT' 2>/dev/null || du -s '$TRINITY_WEB_DOCROOT'" | awk '{print $1}')"
    dk exec "$TRINITY_WEB_CONTAINER" sha256sum /etc/nginx/nginx.conf >"$work/served-nginx.sha256" 2>/dev/null || true
  else
    : >"$out/served-ui.sha256"
    warn "web container $TRINITY_WEB_CONTAINER is not running; served UI not hashed"
  fi
  if [[ -d "$TRINITY_ROOT/apps/web" ]]; then
    (cd "$TRINITY_ROOT/apps/web" && find . -type f \( -name '*.html' -o -name '*.css' -o -name '*.js' -o -path './assets/*' \) -exec sha256sum {} + ) \
      | sed 's#  \./#  #' | LC_ALL=C sort -k2 >"$out/source-ui.sha256"
  else
    : >"$out/source-ui.sha256"
  fi
  local cmp_json='null'
  if [[ -s "$out/served-ui.sha256" ]]; then
    cmp_json="$("$PYTHON" "$HELPER" compare "$out/served-ui.sha256" "$out/source-ui.sha256" --left-label served --right-label source)"
  fi
  printf '{"container": "%s", "image_id": "%s", "docroot": "%s", "served_file_count": %s, "served_bytes": "%s", "served_vs_source": %s}\n' \
    "$TRINITY_WEB_CONTAINER" "$web_image" "$TRINITY_WEB_DOCROOT" "$served_count" "$served_bytes" "$cmp_json" >"$raw/ui.json"
  ok "served UI hashed: $served_count files"

  # ---- schema and privilege shape (read-only) ---------------------------------
  local ledger="$work/ledger.txt"
  if container_running "$TRINITY_DB_CONTAINER" && _db_exec_ro 'SELECT 1' >/dev/null 2>&1; then
    _db_exec_ro "SELECT version()" >"$raw/db-server.txt" || true
    _db_exec_ro "SELECT version FROM blackwell.schema_migrations ORDER BY version" >"$ledger" 2>/dev/null || : >"$ledger"
    _db_exec_ro "SELECT rolname||' login='||rolcanlogin||' super='||rolsuper||' bypassrls='||rolbypassrls||' inherit='||rolinherit||' createrole='||rolcreaterole||' createdb='||rolcreatedb FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname" >"$raw/db-roles.txt" || true
    _db_exec_ro "SELECT r.rolname||' member_of '||g.rolname FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.member JOIN pg_roles g ON g.oid=m.roleid WHERE g.rolname !~ '^pg_' ORDER BY 1" >"$raw/db-role-members.txt" || true
    _db_exec_ro "SELECT usename||' application='||coalesce(nullif(application_name,''),'-')||' connections='||count(*) FROM pg_stat_activity WHERE usename IS NOT NULL GROUP BY usename, application_name ORDER BY 1" >"$raw/db-sessions.txt" || true
    _db_exec_ro "SELECT extname||' '||extversion FROM pg_extension ORDER BY 1" >"$raw/db-extensions.txt" || true
    _db_exec_ro "SELECT coalesce(r.rolname,'PUBLIC')||' '||c.relkind::text||' '||n.nspname||'.'||c.relname||' '||a.privilege_type FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) a LEFT JOIN pg_roles r ON r.oid=a.grantee WHERE n.nspname='blackwell' AND a.grantee <> c.relowner ORDER BY 1" >"$raw/db-table-grants.txt" || true
    _db_exec_ro "SELECT coalesce(r.rolname,'PUBLIC')||' '||n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||') '||a.privilege_type||' secdef='||p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a LEFT JOIN pg_roles r ON r.oid=a.grantee WHERE n.nspname='blackwell' AND a.grantee <> p.proowner ORDER BY 1" >"$raw/db-function-grants.txt" || true
    ok "schema ledger and role/privilege shape (read-only session)"
  else
    : >"$ledger"
    echo "database container unavailable or local read-only session refused" >"$raw/db-server.txt"
    warn "database not inspected"
  fi
  local migdir=""
  [[ -d "$TRINITY_ROOT/database/migrations" ]] && migdir="$TRINITY_ROOT/database/migrations"
  "$PYTHON" "$HELPER" migrations ${migdir:+--migrations-dir "$migdir"} --ledger "$ledger" >"$raw/migrations.json"

  # ---- configuration and secrets (metadata only) ------------------------------
  {
    local f
    for f in "$TRINITY_ROOT"/compose*.yaml "$TRINITY_ROOT"/edge/caddy/Caddyfile "$TRINITY_ROOT"/apps/web/nginx*.conf "$TRINITY_ROOT"/policies/*.toml; do
      [[ -f "$f" ]] && printf '%s %s\n' "$(sha256_file "$f")" "${f#"$TRINITY_ROOT"/}"
    done
  } >"$raw/config-hashes.txt"
  {
    local f
    for f in "$TRINITY_ROOT"/secrets/* /etc/blackwell/* "$TRINITY_ROOT"/.env "$TRINITY_ROOT"/edge/caddy/auth.caddy; do
      [[ -e "$f" ]] || continue
      stat -c '%n mode=%a owner=%U:%G size=%s modified=%y' "$f" 2>/dev/null
    done
  } >"$raw/secret-files.txt"
  if [[ -f "$TRINITY_ROOT/.env" ]]; then
    sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$TRINITY_ROOT/.env" | sort -u >"$raw/env-keys.txt"
  fi
  ok "configuration hashes and secret metadata (no values)"

  # ---- public exposure (GET/HEAD only, no credentials) ---------------------------
  if ((probe)) && command -v curl >/dev/null 2>&1; then
    {
      local path code
      for path in / /health /api/v1/runtime/state /operator/session; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${TRINITY_DOMAIN}${path}" 2>/dev/null || echo error)"
        echo "GET ${path} -> ${code}"
      done
      curl -sI --max-time 8 "https://${TRINITY_DOMAIN}/" 2>/dev/null \
        | grep -iE '^(strict-transport-security|x-content-type-options|x-frame-options|referrer-policy|permissions-policy|content-security-policy|www-authenticate|server):' \
        | tr -d '\r' | sed 's/^/header /'
    } >"$raw/exposure.txt"
    ok "public exposure probe"
  fi

  "$PYTHON" "$HELPER" assemble --raw "$raw" --out "$out" --generated-at "$(utc_iso)"
  rm -rf "$work"
  scan_secrets_or_die "$out/manifest.json" "$out/summary.txt" "$raw"/*
  write_checksums "$out"
  ok "discovery complete: $out/summary.txt"
  printf '%s\n' "$out"
}
