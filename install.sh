#!/usr/bin/env bash
# THE BLACK WELL TRINITY — one-command installer entry point.
#
#   sudo ./install.sh                 existing VPS: install the toolkit, then PROTECT
#                                     (read-only discovery, UI snapshot, proven backup)
#   sudo ./install.sh --guard         ...and enable the hourly UI drift guard
#   sudo ./install.sh --fresh [...]   new host: full Trinity install (see: trinity install --help)
#   sudo ./install.sh --tool-only     only install the `trinity` command
#
# On an existing installation this script never stops, restarts, rebuilds or
# migrates anything, and never touches Edge.
set -Eeuo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
prefix="${TRINITY_INSTALLER_PREFIX:-/opt/trinity-installer}"
mode=protect guard=0
args=()
while (($#)); do
  case "$1" in
    --fresh) mode=fresh ;;
    --tool-only) mode=tool ;;
    --guard) guard=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$1") ;;
  esac
  shift
done

[[ "$(id -u)" == 0 ]] || { echo "run with sudo: sudo $0 $*" >&2; exit 1; }

# 1. Install the toolkit (versioned copy + /usr/local/sbin/trinity).
if [[ "$here" != "$prefix" ]]; then
  install -d -m 755 "$prefix"
  rm -rf "${prefix:?}/bin" "${prefix:?}/lib"
  cp -R "$here/bin" "$here/lib" "$prefix/"
  if [[ -f "$here/README.md" ]]; then cp "$here/README.md" "$prefix/"; fi
  if [[ -d "$here/docs" ]]; then cp -R "$here/docs" "$prefix/"; fi
  if git -C "$here" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$here" rev-parse HEAD >"$prefix/INSTALLER_COMMIT"
  fi
  chmod -R go-w "$prefix"
  chmod 755 "$prefix/bin/trinity"
fi
ln -sfn "$prefix/bin/trinity" /usr/local/sbin/trinity
echo "[trinity] toolkit installed: /usr/local/sbin/trinity -> $prefix/bin/trinity" >&2

case "$mode" in
  tool) exit 0 ;;
  fresh) exec /usr/local/sbin/trinity install "${args[@]}" ;;
esac

# 2. Existing installation: protect first, change nothing.
/usr/local/sbin/trinity preflight || true
/usr/local/sbin/trinity "${args[@]}" protect
if ((guard)); then
  /usr/local/sbin/trinity ui guard install
fi
