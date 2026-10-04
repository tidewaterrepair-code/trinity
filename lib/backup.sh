# shellcheck shell=bash
# trinity backup — tested recovery bundle of the installed system.
#
# A backup is not considered proven because a dump command returned success
# (TRINITY-RECOVERY.md). By default the database dump is restored into a
# disposable, network-less PostgreSQL container and compared with production.

backup_usage() {
  cat <<'EOF'
Usage: trinity backup [options]
       trinity backup secrets --out FILE.enc [--with-oauth]

Creates a private, checksummed recovery bundle (no secret values):
  source/   git bundle(s) of every checkout + tar of modified/untracked work
  db/       pg_dump (custom format), role shape without passwords, ledger, row counts
  data/     Vault/worker bind-mounted data under the checkout's data/
  runtime/  sanitized container/image/volume/network inventory + non-secret config
  images/   docker save of every running blackwell image (with --with-images)

Options:
  --with-images        also save every running blackwell-* image (large)
  --no-data            skip the data/ directory
  --no-restore-proof   skip the disposable restore test (backup is then UNPROVEN)

'backup secrets' writes ONE passphrase-encrypted file (AES-256, PBKDF2) holding
secrets/, /etc/blackwell, .env and Caddy auth. Keep it off the VPS, separate
from the main bundle. The passphrase is read from the terminal and never stored.
EOF
}

_backup_db() {
  local dir="$1" user db
  user="$(_db_env POSTGRES_USER)"; db="$(_db_env POSTGRES_DB)"
  [[ -n "$user" && -n "$db" ]] || die "cannot read POSTGRES_USER/POSTGRES_DB from $TRINITY_DB_CONTAINER"
  mkdir -p "$dir"
  # Row counts are taken before and after the dump; the restore proof requires the
  # restored counts to fall inside that window (production keeps writing meanwhile).
  _db_exec_ro "$(_row_count_sql)" 600000 >"$dir/row-counts-before.txt"
  log "dumping database $db (custom format)"
  dk exec "$TRINITY_DB_CONTAINER" pg_dump -U "$user" -d "$db" -Fc --no-password >"$dir/database.dump"
  [[ -s "$dir/database.dump" ]] || die "pg_dump produced an empty file"
  dk exec "$TRINITY_DB_CONTAINER" pg_dumpall -U "$user" --roles-only --no-role-passwords >"$dir/roles.sql"
  dk exec -i "$TRINITY_DB_CONTAINER" pg_restore -l <"$dir/database.dump" >"$dir/dump-listing.txt"
  _db_exec_ro "SELECT version FROM blackwell.schema_migrations ORDER BY version" >"$dir/ledger.txt" 2>/dev/null || : >"$dir/ledger.txt"
  _db_exec_ro "$(_row_count_sql)" 600000 >"$dir/row-counts-after.txt"
  printf '%s\n%s\n' "$user" "$db" >"$dir/identity.txt"
  ok "database dumped: $(du -h "$dir/database.dump" | awk '{print $1}'), ledger rows $(wc -l <"$dir/ledger.txt" | tr -d ' ')"
}

_row_count_sql() {
  # Exact per-table row counts for every ordinary table in the blackwell schema.
  cat <<'SQL'
SELECT format('%s %s', c.relname,
  (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'blackwell' AND c.relkind IN ('r','p')
ORDER BY c.relname
SQL
}

# Applies a `pg_dumpall --roles-only` file. The bootstrap superuser already
# exists in any target, so errors are tolerated and every role is then checked.
_restore_roles() {
  local container="$1" file="$2" user="$3" missing
  dk exec -i "$container" psql -X -q -U "$user" -d postgres <"$file" >/dev/null 2>&1 || true
  missing="$(sed -n 's/^CREATE ROLE \([^;]*\);$/\1/p' "$file" | tr -d '"' | while read -r r; do
    [[ "$(dk exec "$container" psql -X -At -U "$user" -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '$r'")" == 1 ]] || echo "$r"
  done)"
  [[ -z "$missing" ]] || die "roles missing after role restore: $missing"
}

_restore_proof() {
  local dir="$1" user db name pw ready=false
  user="$(sed -n 1p "$dir/identity.txt")"; db="$(sed -n 2p "$dir/identity.txt")"
  name="trinity-restore-proof-$(utc_stamp | tr 'A-Z' 'a-z')"
  pw="$(openssl rand -hex 24)"
  log "restore proof: disposable container $name (no network, tmpfs storage)"
  on_exit "dk rm -f '$name' >/dev/null 2>&1 || true"
  dk run -d --name "$name" --network none --memory 2g --pids-limit 256 \
    --tmpfs /var/lib/postgresql/data:rw,size=4g \
    -e POSTGRES_USER="$user" -e POSTGRES_DB="$db" -e POSTGRES_PASSWORD="$pw" \
    "$TRINITY_POSTGRES_IMAGE" >/dev/null
  local i
  for i in $(seq 1 60); do
    if dk exec "$name" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SELECT 1"' >/dev/null 2>&1; then
      ready=true; break
    fi
    sleep 1
  done
  [[ "$ready" == true ]] || die "restore proof: scratch PostgreSQL did not become ready"
  # Roles first (the bootstrap superuser already exists, so that one error is expected).
  _restore_roles "$name" "$dir/roles.sql" "$user"
  dk exec -i "$name" pg_restore -U "$user" -d "$db" --exit-on-error <"$dir/database.dump" >"$dir/restore-proof.log" 2>&1 \
    || die "restore proof FAILED: pg_restore error (see $dir/restore-proof.log)"
  dk exec "$name" psql -X -At -U "$user" -d "$db" -c "SELECT version FROM blackwell.schema_migrations ORDER BY version" >"$dir/restore-ledger.txt" 2>/dev/null || : >"$dir/restore-ledger.txt"
  dk exec "$name" psql -X -At -U "$user" -d "$db" -c "$(_row_count_sql)" >"$dir/restore-row-counts.txt"
  cmp -s "$dir/ledger.txt" "$dir/restore-ledger.txt" || die "restore proof FAILED: migration ledger differs after restore"
  local verdict
  verdict="$("$PYTHON" - "$dir/row-counts-before.txt" "$dir/row-counts-after.txt" "$dir/restore-row-counts.txt" <<'PY'
import sys
def load(p):
    out = {}
    for line in open(p):
        if line.strip():
            name, n = line.split()
            out[name] = int(n)
    return out
before, after, restored = (load(p) for p in sys.argv[1:4])
bad = []
for t in sorted(set(before) | set(after) | set(restored)):
    if t not in restored or t not in before or t not in after:
        bad.append(f"{t}: table missing in one side")
        continue
    lo, hi = sorted((before[t], after[t]))
    if not lo <= restored[t] <= hi:
        bad.append(f"{t}: restored {restored[t]} outside [{lo},{hi}]")
moved = sum(1 for t in before if t in after and before[t] != after[t])
if bad:
    print("FAIL " + "; ".join(bad[:10]))
elif moved:
    print(f"PASS tables={len(restored)} (live writes in {moved} table(s) during dump; restored counts within window)")
else:
    print(f"PASS tables={len(restored)} exact")
PY
)"
  [[ "$verdict" == PASS* ]] || die "restore proof FAILED: $verdict"
  echo "$verdict ledger=$(wc -l <"$dir/ledger.txt" | tr -d ' ')" >"$dir/restore-proof-result.txt"
  ok "restore proof: $(cat "$dir/restore-proof-result.txt")"
}

_backup_source() {
  local dir="$1" n=0 repo
  mkdir -p "$dir"
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    local tag="repo-$n"
    echo "$tag $repo" >>"$dir/repos.txt"
    git_at "$repo" bundle create "$dir/$tag.bundle" --all 2>/dev/null || die "git bundle failed for $repo"
    git_at "$repo" bundle verify "$dir/$tag.bundle" >/dev/null 2>&1 || die "git bundle verify failed for $repo"
    git_at "$repo" rev-parse HEAD >"$dir/$tag.head"
    git_at "$repo" status --porcelain=v1 >"$dir/$tag.status" || true
    # Modified + untracked (non-ignored) files. Ignored paths (secrets/, .env, data/) are excluded here.
    git_at "$repo" ls-files -z --modified --others --exclude-standard >"$dir/$tag.work.list" || true
    if [[ -s "$dir/$tag.work.list" ]]; then
      tar -C "$repo" --null --ignore-failed-read -T "$dir/$tag.work.list" -cf "$dir/$tag.work.tar" 2>/dev/null || true
    fi
    tr '\0' '\n' <"$dir/$tag.work.list" >"$dir/$tag.work.txt"; rm -f "$dir/$tag.work.list"
    ok "source $repo: bundle verified, $(wc -l <"$dir/$tag.work.txt" | tr -d ' ') uncommitted/untracked files kept"
    n=$((n + 1))
  done < <(_discover_checkouts)
  ((n > 0)) || warn "no git checkouts found to bundle"
}

_backup_runtime() {
  local dir="$1" ids f
  mkdir -p "$dir/config"
  ids="$(dk ps -aq --filter name=blackwell || true)"
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    dk container inspect $ids | "$PYTHON" "$HELPER" sanitize-inspect >"$dir/containers.json"
  fi
  dk image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Digest}}' >"$dir/images.txt"
  dk volume ls --format '{{.Name}}' >"$dir/volumes.txt"
  dk network ls --format '{{.Name}} {{.Driver}} internal={{.Internal}}' >"$dir/networks.txt"
  for f in "$TRINITY_ROOT"/compose*.yaml "$TRINITY_ROOT"/edge/caddy/Caddyfile "$TRINITY_ROOT"/apps/web/nginx*.conf \
           "$TRINITY_ROOT"/policies/actions.toml "$TRINITY_ROOT"/config/*.json "$TRINITY_ROOT"/.env.example; do
    [[ -f "$f" ]] && install -D -m 600 "$f" "$dir/config/${f#"$TRINITY_ROOT"/}"
  done
  for f in "$TRINITY_ROOT"/secrets/* /etc/blackwell/* "$TRINITY_ROOT"/.env "$TRINITY_ROOT"/edge/caddy/auth.caddy; do
    [[ -e "$f" ]] && stat -c '%n mode=%a owner=%U:%G size=%s' "$f"
  done >"$dir/secret-files-metadata.txt"
  edge_identity >"$dir/edge-identity.txt"
  scan_secrets_or_die "$dir/containers.json" "$dir/secret-files-metadata.txt"
  ok "runtime inventory and non-secret configuration"
}

_backup_images() {
  local dir="$1" c img safe
  mkdir -p "$dir"
  declare -A seen=()
  for c in $(dk ps --format '{{.Names}}' --filter name=blackwell); do
    img="$(dk container inspect -f '{{.Image}}' "$c")"
    [[ -n "${seen[$img]:-}" ]] && continue
    seen[$img]=1
    safe="${img#sha256:}"
    dk image save -o "$dir/${c}-${safe:0:12}.tar" "$img"
    echo "$c $img" >>"$dir/images.txt"
  done
  ok "images saved: ${#seen[@]}"
}

_backup_space_check() {
  # Refuses to start if the backup could fill the disk (a full disk can stop PostgreSQL).
  local dir="$1" with_data="$2" need=0 avail db_bytes data_bytes repo_bytes
  db_bytes="$(_db_exec_ro "SELECT pg_database_size(current_database())" 2>/dev/null || echo 0)"
  data_bytes=0; ((with_data)) && [[ -d "$TRINITY_ROOT/data" ]] && data_bytes="$(du -sb "$TRINITY_ROOT/data" | awk '{print $1}')"
  repo_bytes="$(du -sb "$TRINITY_ROOT/.git" 2>/dev/null | awk '{print $1}' || echo 0)"
  need=$(( (db_bytes + data_bytes + repo_bytes) * 2 + 2 * 1024 * 1024 * 1024 ))
  avail="$(df -PB1 "$dir" | awk 'NR==2{print $4}')"
  if ((avail < need)); then
    rmdir "$dir" 2>/dev/null || true
    die "not enough free space for a safe backup: need ~$((need / 1024 / 1024)) MiB (2x data + 2 GiB reserve), have $((avail / 1024 / 1024)) MiB at $(dirname "$dir")"
  fi
  log "free space ok: $((avail / 1024 / 1024)) MiB available, ~$((need / 1024 / 1024)) MiB reserved"
}

backup_run() {
  if [[ "${1:-}" == secrets ]]; then shift; backup_secrets "$@"; return; fi
  local with_images=0 with_data=1 proof=1
  while (($#)); do
    case "$1" in
      --with-images) with_images=1 ;;
      --no-data) with_data=0 ;;
      --no-restore-proof) proof=0 ;;
      -h|--help) backup_usage; return 0 ;;
      *) die "backup: unknown option $1" ;;
    esac
    shift
  done
  require_cmd openssl tar sha256sum
  acquire_lock
  local root="$TRINITY_STATE_DIR/backups" stamp dir
  stamp="$(utc_stamp)"; dir="$root/$stamp"
  umask 077; mkdir -p "$dir"
  _backup_space_check "$dir" "$with_data"
  log "backup: $dir"
  fence_begin

  _backup_source "$dir/source"
  if container_running "$TRINITY_DB_CONTAINER"; then
    _backup_db "$dir/db"
    if ((proof)); then _restore_proof "$dir/db"; else echo "NOT_RUN" >"$dir/db/restore-proof-result.txt"; warn "restore proof skipped: this backup is UNPROVEN"; fi
  else
    warn "database container not running; no database dump in this backup"
  fi
  if ((with_data)) && [[ -d "$TRINITY_ROOT/data" ]]; then
    mkdir -p "$dir/data"
    tar -C "$TRINITY_ROOT" -cf "$dir/data/data.tar" data
    ok "data/ archived ($(du -h "$dir/data/data.tar" | awk '{print $1}'))"
  fi
  _backup_runtime "$dir/runtime"
  ((with_images)) && _backup_images "$dir/images"

  STAMP="$stamp" EDGE="$(edge_identity)" PROOF="$(cat "$dir/db/restore-proof-result.txt" 2>/dev/null || echo NO_DATABASE)" \
  "$PYTHON" - >"$dir/backup.json" <<'PY'
import json, os
print(json.dumps({
  "schema": "trinity.installer.backup.v1",
  "created_utc": os.environ["STAMP"],
  "restore_proof": os.environ["PROOF"],
  "edge_identity": os.environ["EDGE"],
  "excluded_by_design": [
    "secret values (use: trinity backup secrets)",
    "blackwell_codex_home OAuth volume",
    "Caddy TLS data volume (re-issued automatically)",
  ],
}, indent=2))
PY
  fence_assert_unchanged
  write_checksums "$dir"
  chmod -R a-w "$dir"
  ok "backup complete: $dir ($(du -sh "$dir" | awk '{print $1}'))"
  log "copy it off the VPS: see README section 1 (package with sudo tar, then scp from your computer)"
  printf '%s\n' "$dir"
}

backup_secrets() {
  local out="" with_oauth=0
  while (($#)); do
    case "$1" in
      --out) out="$2"; shift ;;
      --with-oauth) with_oauth=1 ;;
      *) die "backup secrets: unknown option $1" ;;
    esac
    shift
  done
  [[ -n "$out" ]] || die "backup secrets requires --out FILE.enc"
  [[ -e "$out" ]] && die "$out already exists"
  require_root
  require_cmd openssl tar
  [[ -t 0 ]] || die "backup secrets needs a terminal to read the passphrase"
  local pass pass2 tmp
  read -r -s -p "Encryption passphrase (min 16 chars): " pass; echo >&2
  read -r -s -p "Repeat passphrase: " pass2; echo >&2
  [[ "$pass" == "$pass2" ]] || die "passphrases differ"
  ((${#pass} >= 16)) || die "passphrase too short"
  tmp="$(mktemp -d)"
  on_exit "rm -rf '$tmp'"
  umask 077
  local -a items=()
  [[ -d "$TRINITY_ROOT/secrets" ]] && items+=("$TRINITY_ROOT/secrets")
  [[ -d /etc/blackwell ]] && items+=(/etc/blackwell)
  [[ -f "$TRINITY_ROOT/.env" ]] && items+=("$TRINITY_ROOT/.env")
  [[ -f "$TRINITY_ROOT/edge/caddy/auth.caddy" ]] && items+=("$TRINITY_ROOT/edge/caddy/auth.caddy")
  if ((with_oauth)); then
    dk run --rm --network none -v blackwell_codex_home:/src:ro "$TRINITY_POSTGRES_IMAGE" tar -C /src -cf - . >"$tmp/codex_home.tar"
    items+=("$tmp/codex_home.tar")
  fi
  ((${#items[@]})) || die "no secret material found to back up"
  tar -cPf "$tmp/secrets.tar" "${items[@]}"
  openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in "$tmp/secrets.tar" -out "$out" -pass fd:3 3<<<"$pass"
  unset pass pass2
  chmod 400 "$out"
  ok "encrypted secrets written to $out ($(du -h "$out" | awk '{print $1}'))"
  log "decrypt later with: openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in $(basename "$out") -out secrets.tar"
  log "move it OFF the VPS and store it apart from the main backup bundle"
}
