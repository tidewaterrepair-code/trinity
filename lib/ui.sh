# shellcheck shell=bash
# trinity ui — preserve, verify, guard and restore the installed Command Cathedral.
#
# The served UI (what the browser actually receives from the web container)
# is the visual baseline. Snapshots capture the served files, the exact web
# image and the source tree including untracked refinements, all checksummed
# and made read-only.

UI_SNAPSHOT_ROOT_DEFAULT() { printf '%s/ui-snapshots' "$TRINITY_STATE_DIR"; }

ui_usage() {
  cat <<'EOF'
Usage: trinity ui <command> [options]

  preserve [--no-image] [--immutable]
        Snapshot the live served UI, the running web image and apps/web source
        (including untracked files). Read-only to production.
  verify [--snapshot DIR] [--quiet]
        Compare the live served UI with a snapshot (default: latest). Exit 1 on drift.
  list  List snapshots.
  export [--snapshot DIR]
        Pack a snapshot into one .tar for off-host safekeeping.
  guard install|remove|status
        Hourly systemd check that alerts (journal) if the served UI drifts.
  restore --snapshot DIR [--yes]
        Put a preserved UI back: reload/retag the preserved web image and
        recreate ONLY the web container. Edge is never touched.
EOF
}

_ui_root() { printf '%s' "${TRINITY_UI_SNAPSHOT_ROOT:-$(UI_SNAPSHOT_ROOT_DEFAULT)}"; }

_ui_latest() {
  local root; root="$(_ui_root)"
  [[ -L "$root/latest" ]] || die "no UI snapshot exists yet (run: trinity ui preserve)"
  readlink -f "$root/latest"
}

_ui_live_manifest() {
  # sha256 manifest of the files the web container is serving right now.
  container_running "$TRINITY_WEB_CONTAINER" || die "web container $TRINITY_WEB_CONTAINER is not running"
  dk exec "$TRINITY_WEB_CONTAINER" sh -c "cd '$TRINITY_WEB_DOCROOT' && find . -type f -exec sha256sum {} +" \
    | sed 's#  \./#  #' | LC_ALL=C sort -k2
}

ui_preserve() {
  local with_image=1 immutable=0 set_latest=1 label=""
  while (($#)); do
    case "$1" in
      --no-image) with_image=0 ;;
      --no-latest) set_latest=0 ;;
      --label) label="$2"; shift ;;
      --immutable) immutable=1 ;;
      -h|--help) ui_usage; return 0 ;;
      *) die "ui preserve: unknown option $1" ;;
    esac
    shift
  done
  container_running "$TRINITY_WEB_CONTAINER" || die "web container $TRINITY_WEB_CONTAINER is not running; nothing live to preserve"

  local root stamp snap image_id image_ref tag
  root="$(_ui_root)"; stamp="$(utc_stamp)"; snap="$root/$stamp${label:+-$label}"
  umask 077
  mkdir -p "$root"
  local avail; avail="$(df -PB1 "$root" | awk 'NR==2{print $4}')"
  ((avail > 1024 * 1024 * 1024)) || die "less than 1 GiB free at $root; not writing a UI snapshot (a full disk can stop production services)"
  mkdir -p "$snap/served" "$snap/source"
  log "UI snapshot: $snap"

  # 1. Served files, copied out of the running container.
  _ui_live_manifest >"$snap/served.sha256"
  dk cp "$TRINITY_WEB_CONTAINER:$TRINITY_WEB_DOCROOT/." "$snap/served/html"
  dk cp "$TRINITY_WEB_CONTAINER:/etc/nginx/nginx.conf" "$snap/served/nginx.conf" 2>/dev/null || warn "nginx.conf not copied"
  # Prove the copy is byte-identical to what is being served.
  (cd "$snap/served/html" && find . -type f -exec sha256sum {} + | sed 's#  \./#  #' | LC_ALL=C sort -k2) >"$snap/served-copy.sha256"
  cmp -s "$snap/served.sha256" "$snap/served-copy.sha256" || die "copied UI does not match the served UI hashes"
  rm -f "$snap/served-copy.sha256"
  ok "served UI copied and hash-verified ($(wc -l <"$snap/served.sha256" | tr -d ' ') files)"

  # 2. The exact running web image.
  image_id="$(dk container inspect -f '{{.Image}}' "$TRINITY_WEB_CONTAINER")"
  image_ref="$(dk container inspect -f '{{.Config.Image}}' "$TRINITY_WEB_CONTAINER")"
  tag="trinity-ui-preserved:${stamp,,}"
  dk image tag "$image_id" "$tag"
  ok "running web image pinned as $tag"
  if ((with_image)); then
    dk image save -o "$snap/web-image.tar" "$tag"
    ok "web image saved ($(du -h "$snap/web-image.tar" | awk '{print $1}'))"
  fi

  # 3. Source tree, including untracked/uncommitted refinements.
  local src_commit="unknown" src_dirty="unknown"
  if [[ -d "$TRINITY_ROOT/apps/web" ]]; then
    tar -C "$TRINITY_ROOT/apps" -cf "$snap/source/apps-web.tar" web
    src_commit="$(git_root rev-parse HEAD 2>/dev/null || echo unknown)"
    git_root status --porcelain=v1 -- apps/web >"$snap/source/git-status.txt" 2>/dev/null || true
    [[ -s "$snap/source/git-status.txt" ]] && src_dirty=yes || src_dirty=no
    ok "apps/web source archived (dirty=$src_dirty)"
  else
    warn "no source at $TRINITY_ROOT/apps/web; only the served copy is preserved"
  fi
  for f in docs/COMMAND-CATHEDRAL-V7.md apps/web/nginx.conf compose.yaml; do
    [[ -f "$TRINITY_ROOT/$f" ]] && install -D -m 600 "$TRINITY_ROOT/$f" "$snap/source/ref/$f"
  done

  # 4. Provenance.
  STAMP="$stamp" IMAGE_ID="$image_id" IMAGE_REF="$image_ref" TAG="$tag" WITH_IMAGE="$with_image" \
  SRC_COMMIT="$src_commit" SRC_DIRTY="$src_dirty" CONTAINER="$TRINITY_WEB_CONTAINER" \
  CONTAINER_ID="$(dk container inspect -f '{{.Id}}' "$TRINITY_WEB_CONTAINER")" \
  STARTED="$(dk container inspect -f '{{.State.StartedAt}}' "$TRINITY_WEB_CONTAINER")" \
  REPO_DIGESTS="$(dk image inspect -f '{{join .RepoDigests " "}}' "$image_id" 2>/dev/null || true)" \
  EDGE="$(edge_identity)" HOSTNAME_V="$(hostname)" \
  "$PYTHON" - >"$snap/provenance.json" <<'PY'
import json, os
e = os.environ
print(json.dumps({
  "schema": "trinity.ui.snapshot.v1",
  "created_utc": e["STAMP"], "host": e["HOSTNAME_V"],
  "web_container": e["CONTAINER"], "web_container_id": e["CONTAINER_ID"], "web_started_at": e["STARTED"],
  "web_image_id": e["IMAGE_ID"], "web_image_ref": e["IMAGE_REF"], "web_image_repo_digests": e["REPO_DIGESTS"].split(),
  "pinned_tag": e["TAG"], "image_tar_included": e["WITH_IMAGE"] == "1",
  "source_commit": e["SRC_COMMIT"], "source_apps_web_dirty": e["SRC_DIRTY"],
  "edge_identity_at_capture": e["EDGE"],
  "contents": {
    "served/html": "exact files served by the web container",
    "served/nginx.conf": "nginx configuration inside the running web container",
    "served.sha256": "hash manifest of the served files",
    "web-image.tar": "docker save of the exact running web image (if included)",
    "source/apps-web.tar": "apps/web from the checkout incl. untracked files",
  },
}, indent=2))
PY

  write_checksums "$snap"
  chmod -R a-w "$snap"
  if ((immutable)); then
    if [[ "$(id -u)" == 0 ]] && command -v chattr >/dev/null 2>&1; then
      chattr -R +i "$snap" && ok "snapshot marked immutable (chattr +i)"
    else
      warn "--immutable needs root and chattr; snapshot is read-only but not immutable"
    fi
  fi
  ((set_latest)) && ln -sfn "$(basename "$snap")" "$root/latest"
  ok "UI preserved: $snap"
  printf '%s\n' "$snap"
}

ui_verify() {
  local snap="" quiet=0
  while (($#)); do
    case "$1" in
      --snapshot) snap="$2"; shift ;;
      --quiet) quiet=1 ;;
      -h|--help) ui_usage; return 0 ;;
      *) die "ui verify: unknown option $1" ;;
    esac
    shift
  done
  [[ -n "$snap" ]] || snap="$(_ui_latest)"
  verify_checksums "$snap"
  local tmp rc=0 result
  tmp="$(mktemp)"
  _ui_live_manifest >"$tmp"
  result="$("$PYTHON" "$HELPER" compare "$snap/served.sha256" "$tmp" --left-label snapshot --right-label live --strict --brief)" || rc=$?
  rm -f "$tmp"
  local live_image snap_image
  live_image="$(dk container inspect -f '{{.Image}}' "$TRINITY_WEB_CONTAINER")"
  snap_image="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["web_image_id"])' "$snap/provenance.json")"
  if ((rc == 0)); then
    if [[ "$live_image" == "$snap_image" ]]; then
      ((quiet)) || ok "served UI matches snapshot $(basename "$snap") (same image)"
    else
      ((quiet)) || ok "served UI files match snapshot $(basename "$snap") (image rebuilt: $live_image)"
    fi
    command -v logger >/dev/null && logger -t trinity-ui-guard "UI OK vs $(basename "$snap")" || true
    return 0
  fi
  command -v logger >/dev/null && logger -p user.warning -t trinity-ui-guard "UI DRIFT vs $(basename "$snap")" || true
  warn "served UI differs from snapshot $(basename "$snap"):"
  printf '%s\n' "$result" >&2
  return 1
}

ui_list() {
  local root d; root="$(_ui_root)"
  [[ -d "$root" ]] || { log "no snapshots"; return 0; }
  for d in "$root"/*/; do
    [[ -L "${d%/}" ]] && continue
    [[ -f "$d/provenance.json" ]] || continue
    "$PYTHON" - "$d" <<'PY'
import json, sys, os
p = json.load(open(os.path.join(sys.argv[1], "provenance.json")))
print(f'{os.path.basename(sys.argv[1].rstrip("/"))}  image={p["web_image_id"][:19]}  source={p["source_commit"][:12]} dirty={p["source_apps_web_dirty"]}  image_tar={p["image_tar_included"]}')
PY
  done
  [[ -L "$root/latest" ]] && log "latest -> $(readlink "$root/latest")"
}

ui_export() {
  local snap=""
  while (($#)); do
    case "$1" in
      --snapshot) snap="$2"; shift ;;
      *) die "ui export: unknown option $1" ;;
    esac
    shift
  done
  [[ -n "$snap" ]] || snap="$(_ui_latest)"
  verify_checksums "$snap"
  local out
  out="$(_ui_root)/export-$(basename "$snap").tar"
  umask 077
  tar -C "$(dirname "$snap")" -cf "$out" "$(basename "$snap")"
  sha256sum "$out" >"$out.sha256"
  ok "exported $out"
  log "copy it off the VPS: see README section 1 (package with sudo, then scp from your computer)"
  printf '%s\n' "$out"
}

ui_restore() {
  local snap=""
  while (($#)); do
    case "$1" in
      --snapshot) snap="$2"; shift ;;
      --yes) TRINITY_ASSUME_YES=1 ;;
      *) die "ui restore: unknown option $1" ;;
    esac
    shift
  done
  [[ -n "$snap" ]] || die "ui restore requires --snapshot DIR (see: trinity ui list)"
  snap="$(readlink -f "$snap")"
  verify_checksums "$snap"
  acquire_lock

  local tag image_ref snap_image
  tag="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pinned_tag"])' "$snap/provenance.json")"
  snap_image="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["web_image_id"])' "$snap/provenance.json")"

  if ui_verify --snapshot "$snap" --quiet 2>/dev/null; then
    ln -sfn "$(basename "$snap")" "$(_ui_root)/latest"
    ok "live UI already matches $(basename "$snap"); nothing to restore (drift guard now compares against it)"
    return 0
  fi

  if ! dk image inspect "$tag" >/dev/null 2>&1; then
    [[ -f "$snap/web-image.tar" ]] || die "pinned image $tag is gone and the snapshot has no web-image.tar"
    log "loading preserved web image from snapshot"
    dk image load -i "$snap/web-image.tar" >/dev/null
  fi
  [[ "$(dk image inspect -f '{{.Id}}' "$tag")" == "$snap_image" ]] || die "pinned tag $tag does not resolve to the preserved image"

  compose_adopt_from_container "$TRINITY_WEB_CONTAINER"
  image_ref="$(dk container inspect -f '{{.Config.Image}}' "$TRINITY_WEB_CONTAINER")"
  [[ -n "$image_ref" ]] || die "cannot determine the web image name compose uses"

  log "current UI will be snapshotted first so this restore is itself reversible"
  ui_preserve --no-latest --label pre-restore >/dev/null

  confirm_phrase "RESTORE UI" "This recreates ONLY ${TRINITY_WEB_CONTAINER} from preserved image ${snap_image:0:19}. Edge is not touched."
  fence_begin
  dk image tag "$snap_image" "$image_ref"
  compose_safe up -d --no-deps --no-build web
  local i
  for i in $(seq 1 30); do
    [[ "$(dk container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$TRINITY_WEB_CONTAINER" 2>/dev/null)" =~ ^(healthy|running)$ ]] && break
    sleep 2
  done
  fence_assert_unchanged
  ui_verify --snapshot "$snap" || die "web container recreated but served UI still differs; previous UI is in the pre-restore snapshot"
  ln -sfn "$(basename "$snap")" "$(_ui_root)/latest"
  ok "UI restored from $(basename "$snap"); the drift guard now compares against it"
}

ui_guard() {
  local action="${1:-status}"
  local unit=trinity-ui-guard
  case "$action" in
    install)
      require_root
      command -v systemctl >/dev/null || die "systemd is required for the guard"
      _ui_latest >/dev/null
      cat >/etc/systemd/system/$unit.service <<EOF
[Unit]
Description=Trinity Command Cathedral UI drift check (read-only)

[Service]
Type=oneshot
Environment=TRINITY_STATE_DIR=$TRINITY_STATE_DIR
Environment=TRINITY_WEB_CONTAINER=$TRINITY_WEB_CONTAINER
ExecStart=$TRINITY_INSTALLER_HOME/bin/trinity ui verify --quiet
EOF
      cat >/etc/systemd/system/$unit.timer <<EOF
[Unit]
Description=Hourly Trinity UI drift check

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
      systemctl daemon-reload
      systemctl enable --now $unit.timer
      ok "UI guard installed (journalctl -t trinity-ui-guard)"
      ;;
    remove)
      require_root
      systemctl disable --now $unit.timer 2>/dev/null || true
      rm -f /etc/systemd/system/$unit.service /etc/systemd/system/$unit.timer
      systemctl daemon-reload
      ok "UI guard removed"
      ;;
    status)
      systemctl list-timers $unit.timer --no-pager 2>/dev/null || true
      journalctl -t trinity-ui-guard -n 5 --no-pager 2>/dev/null || true
      ;;
    *) die "ui guard: install|remove|status" ;;
  esac
}

ui_main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    preserve) ui_preserve "$@" ;;
    verify)   ui_verify "$@" ;;
    list)     ui_list ;;
    export)   ui_export "$@" ;;
    guard)    ui_guard "$@" ;;
    restore)  ui_restore "$@" ;;
    ""|-h|--help|help) ui_usage ;;
    *) die "ui: unknown command $sub" ;;
  esac
}
