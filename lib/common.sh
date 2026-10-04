# shellcheck shell=bash
# Shared helpers for the Trinity installer.
#
# Every command sources this file. It defines configuration defaults,
# logging, the Docker wrapper, the Edge fence and the guards that keep
# the installer from mutating production by accident.

: "${TRINITY_INSTALLER_HOME:?TRINITY_INSTALLER_HOME must be set by bin/trinity}"

# ---------------------------------------------------------------------------
# Configuration. Override through the environment or /etc/trinity-installer.conf
# (a plain KEY=value file, sourced as shell). Never put secret values there.
# ---------------------------------------------------------------------------
if [[ -r /etc/trinity-installer.conf && -z "${TRINITY_SKIP_SYSTEM_CONF:-}" ]]; then
  # shellcheck disable=SC1091
  source /etc/trinity-installer.conf
fi

: "${TRINITY_ROOT:=/opt/blackwell}"
: "${TRINITY_COMPOSE_PROJECT:=blackwell}"
: "${TRINITY_MAINT_USER:=blackwell}"
: "${TRINITY_MAINT_HOME:=/home/${TRINITY_MAINT_USER}}"
: "${TRINITY_STATE_DIR:=${TRINITY_MAINT_HOME}/trinity-maintenance/installer}"
: "${TRINITY_WEB_CONTAINER:=blackwell-web}"
: "${TRINITY_EDGE_CONTAINER:=blackwell-edge}"
: "${TRINITY_DB_CONTAINER:=blackwell-postgres}"
: "${TRINITY_WEB_DOCROOT:=/usr/share/nginx/html}"
: "${TRINITY_POSTGRES_IMAGE:=pgvector/pgvector:0.8.5-pg17-bookworm}"
: "${TRINITY_SOURCE_REPO:=https://github.com/tidewaterrepair-code/the-black-well.git}"
# Latest reviewed continuation commit (agent/trinity-completion-20260930).
: "${TRINITY_SOURCE_REF:=445267c03cba59e4538b80663b0a7ed1926a0956}"
: "${TRINITY_DOMAIN:=theblackwell.online}"

# Golden Edge fence from docs/trinity/TRINITY-RECOVERY.md.
: "${TRINITY_EDGE_GOLDEN_ID:=6e0da288cd205c9844cd606862a08bd20abaf22825e37fafbaf85c39595ab84c}"
: "${TRINITY_EDGE_GOLDEN_IMAGE:=sha256:219978e4a0dce28ea0540dbee7fe2f272245eb2eeeb2de2f2f584d525aba0de4}"
: "${TRINITY_EDGE_GOLDEN_STARTED:=2026-08-23T11:49:22.11611867Z}"

# Commits named in the continuation map; discovery reports which are present.
TRINITY_KNOWN_COMMITS=(
  "edd4f0f16d45261c893cc5c0e1ff33fea28f2a01:golden-baseline-v12l-0048"
  "4b776faf767297c45302d6956d09ab35db501911:continuation-baseline-20260930"
  "c6879f8:authenticated-candidate-producer"
  "fce269d:native-seat-run"
  "7bf1dfc:candidate-response-validation"
  "445267c:migration-upgrade-rollback-drills"
)

PYTHON="${PYTHON:-python3}"
HELPER="${TRINITY_INSTALLER_HOME}/lib/trinity_helper.py"

# ---------------------------------------------------------------------------
# Logging. Messages go to stderr so command output stays machine-readable.
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  _c_red=$'\e[31m'; _c_grn=$'\e[32m'; _c_yel=$'\e[33m'; _c_dim=$'\e[2m'; _c_off=$'\e[0m'
else
  _c_red=; _c_grn=; _c_yel=; _c_dim=; _c_off=
fi

log()  { printf '%s[trinity]%s %s\n' "$_c_dim" "$_c_off" "$*" >&2; }
ok()   { printf '%s[  ok  ]%s %s\n' "$_c_grn" "$_c_off" "$*" >&2; }
warn() { printf '%s[ warn ]%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
die()  { printf '%s[ FAIL ]%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }
utc_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# Docker wrapper. Uses plain docker when the caller can reach the daemon,
# otherwise sudo docker. Refuses any invocation that could touch Edge.
# ---------------------------------------------------------------------------
_DOCKER_CMD=()
docker_init() {
  if ((${#_DOCKER_CMD[@]})); then return 0; fi
  command -v docker >/dev/null 2>&1 || die "docker is not installed"
  if docker info >/dev/null 2>&1; then
    _DOCKER_CMD=(docker)
  elif sudo -n docker info >/dev/null 2>&1; then
    _DOCKER_CMD=(sudo -n docker)
  else
    die "cannot reach the Docker daemon (run as root, a docker-group user, or with passwordless sudo for docker)"
  fi
}

dk() {
  docker_init
  "${_DOCKER_CMD[@]}" "$@"
}

container_exists() { dk container inspect "$1" >/dev/null 2>&1; }
container_running() {
  [[ "$(dk container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]
}

# Compose is only ever invoked through this function. It never runs
# down/rm/kill/restart/stop, never touches volumes and never names Edge.
compose_safe() {
  local sub="$1"; shift
  case "$sub" in
    up|build|ps|config|images|pull|create) ;;
    *) die "compose_safe: subcommand '$sub' is not permitted by the installer" ;;
  esac
  local arg
  for arg in "$@"; do
    case "$arg" in
      edge|blackwell-edge|"$TRINITY_EDGE_CONTAINER")
        die "compose_safe: refusing to operate on Edge ($arg)" ;;
      -v|--volumes|--remove-orphans|--force-recreate|--renew-anon-volumes|-V)
        die "compose_safe: flag '$arg' is not permitted" ;;
    esac
  done
  if [[ "$sub" == up ]]; then
    # 'up' must name explicit services and must not cascade into dependencies.
    local has_service=0 has_nodeps=0
    for arg in "$@"; do
      [[ "$arg" == --no-deps ]] && has_nodeps=1
      [[ "$arg" != -* ]] && has_service=1
    done
    if [[ "${TRINITY_ALLOW_DEPS:-0}" != 1 ]]; then
      ((has_nodeps)) || die "compose_safe: 'up' requires --no-deps"
    fi
    ((has_service)) || die "compose_safe: 'up' requires explicit service names"
  fi
  local -a files=()
  local f
  for f in ${TRINITY_COMPOSE_FILES:-}; do files+=(-f "$f"); done
  dk compose --project-directory "$TRINITY_ROOT" -p "$TRINITY_COMPOSE_PROJECT" "${files[@]}" "$sub" "$@"
}

# Adopts the compose project, directory and files that actually started a
# running container, so a recreate uses the same definition as production.
compose_adopt_from_container() {
  local c="$1" project wd files
  project="$(dk container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null || true)"
  wd="$(dk container inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null || true)"
  files="$(dk container inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$c" 2>/dev/null || true)"
  [[ -n "$project" ]] || die "$c was not started by Docker Compose; refusing to guess its definition"
  TRINITY_COMPOSE_PROJECT="$project"
  [[ -n "$wd" ]] && TRINITY_ROOT="$wd"
  TRINITY_COMPOSE_FILES="${files//,/ }"
  log "compose project=$TRINITY_COMPOSE_PROJECT dir=$TRINITY_ROOT files=${TRINITY_COMPOSE_FILES:-default}"
}

# ---------------------------------------------------------------------------
# Edge fence. Records the identity of the protected Edge container so every
# mutating command can prove Edge was not changed.
# ---------------------------------------------------------------------------
edge_identity() {
  if ! container_exists "$TRINITY_EDGE_CONTAINER"; then
    printf 'absent'
    return 0
  fi
  dk container inspect -f '{{.Id}} {{.Image}} {{.State.StartedAt}} {{.State.Status}}' "$TRINITY_EDGE_CONTAINER"
}

edge_fence_status() {
  local id image started status
  read -r id image started status <<<"$(edge_identity)"
  if [[ "$id" == absent ]]; then
    printf 'ABSENT'
  elif [[ "$id" == "$TRINITY_EDGE_GOLDEN_ID" && "$image" == "$TRINITY_EDGE_GOLDEN_IMAGE" ]]; then
    printf 'GOLDEN'
  else
    printf 'DIFFERS_FROM_GOLDEN'
  fi
}

# Usage: fence_begin; ...mutations...; fence_assert_unchanged
_FENCE_BEFORE=
fence_begin() { _FENCE_BEFORE="$(edge_identity)"; }
fence_assert_unchanged() {
  local now
  now="$(edge_identity)"
  [[ "$now" == "$_FENCE_BEFORE" ]] || die "EDGE FENCE VIOLATION: Edge identity changed during this run (before: ${_FENCE_BEFORE}; after: ${now})"
  ok "Edge fence held (Edge unchanged)"
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
require_root() {
  [[ "$(id -u)" == 0 ]] || die "this command must run as root (use sudo)"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# Interactive confirmation for production-affecting actions.
# Skipped only when TRINITY_ASSUME_YES=1 (set by --yes).
confirm_phrase() {
  local phrase="$1" prompt="$2" reply
  if [[ "${TRINITY_ASSUME_YES:-0}" == 1 ]]; then
    log "confirmation '$phrase' supplied by --yes"
    return 0
  fi
  [[ -t 0 ]] || die "confirmation required: re-run interactively or pass --yes"
  printf '%s\nType %s to continue: ' "$prompt" "$phrase" >&2
  read -r reply
  [[ "$reply" == "$phrase" ]] || die "confirmation not given; nothing changed"
}

# Exit-time cleanup registry: every registered command runs once when the
# (sub)shell that registered it exits, including after die(). Entries are
# keyed by BASHPID because command substitutions are separate subshells that
# do not inherit the EXIT trap.
_ON_EXIT=()
_run_on_exit() {
  local i entry
  for ((i = ${#_ON_EXIT[@]} - 1; i >= 0; i--)); do
    entry="${_ON_EXIT[$i]}"
    [[ "${entry%%|*}" == "$BASHPID" ]] || continue
    eval "${entry#*|}" || true
  done
}
on_exit() {
  _ON_EXIT+=("$BASHPID|$1")
  trap _run_on_exit EXIT
}

# Single-run lock so two installer runs never race.
acquire_lock() {
  local lockdir="${TRINITY_STATE_DIR}/.lock"
  mkdir -p "$TRINITY_STATE_DIR"
  if ! mkdir "$lockdir" 2>/dev/null; then
    die "another installer run holds ${lockdir} (remove it only if no installer is running)"
  fi
  printf '%s %s\n' "$$" "$(utc_iso)" >"$lockdir/owner"
  on_exit "rm -rf '$lockdir'"
}

# Creates a private run directory: $TRINITY_STATE_DIR/<stamp>-<name>
new_run_dir() {
  local name="$1" dir
  umask 077
  mkdir -p "$TRINITY_STATE_DIR"
  dir="${TRINITY_STATE_DIR}/$(utc_stamp)-${name}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  printf '%s' "$dir"
}

# Fails (and removes the offending file) if a report contains secret material.
scan_secrets_or_die() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    if ! "$PYTHON" "$HELPER" scan-secrets "$f" >&2; then
      rm -f "$f"
      die "secret-like content detected in $(basename "$f"); the report was deleted"
    fi
  done
}

sha256_file() { sha256sum "$1" | awk '{print $1}'; }

# Writes SHA256SUMS for every regular file below a directory (relative paths).
write_checksums() {
  local dir="$1"
  (cd "$dir" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum >SHA256SUMS)
}

verify_checksums() {
  local dir="$1"
  [[ -f "$dir/SHA256SUMS" ]] || die "no SHA256SUMS in $dir"
  (cd "$dir" && sha256sum --quiet -c SHA256SUMS) || die "checksum verification failed in $dir"
}

git_at() { local d="$1"; shift; git -c safe.directory='*' -C "$d" "$@"; }
git_root() { git_at "$TRINITY_ROOT" "$@"; }
