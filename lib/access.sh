# shellcheck shell=bash
# trinity access — temporary, audited maintenance SSH access.
#
# Implements the enable/disable sequence of docs/trinity/TRINITY-MAINTENANCE-MODE.md:
# explicit operator action, a single temporary public key on the non-root
# maintenance user, a hard expiry enforced by sshd itself, a recorded
# fingerprint and baseline, and verifiable revocation with a closure report.

ACCESS_MARK=trinity-maintenance
ACCESS_MAX_HOURS=72

access_usage() {
  cat <<'EOF'
Usage: trinity access <command>

  grant --pubkey FILE|"ssh-ed25519 AAAA..." [--ttl 8h] [--from CIDR[,CIDR]] [--agent NAME]
        Add ONE temporary key to the maintenance user (default: blackwell).
        sshd itself refuses the key after the expiry (expiry-time option).
        No root login, no agent/X11/port forwarding. Max TTL 72h.
  revoke --session ID | --all | --expired [--kill-sessions]
        Remove the key(s), prove they are gone, write a closure report.
  status
        Active and expired grants, sshd posture, maintenance user groups.
EOF
}

_access_dir() { printf '%s/access' "$TRINITY_STATE_DIR"; }
_access_keys() { printf '%s/.ssh/authorized_keys' "$(getent passwd "$TRINITY_MAINT_USER" | cut -d: -f6)"; }

_ttl_minutes() {
  local t="$1" n unit
  [[ "$t" =~ ^([0-9]+)([mhd])$ ]] || die "--ttl must look like 90m, 8h or 2d"
  n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  case "$unit" in m) echo "$n" ;; h) echo $((n * 60)) ;; d) echo $((n * 1440)) ;; esac
}

_sshd_supports_expiry() {
  # expiry-time appeared in OpenSSH 7.7.
  local v
  v="$( (sshd -V 2>&1 || ssh -V 2>&1) | sed -n 's/.*OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -1)"
  [[ -n "$v" ]] || return 1
  read -r maj min <<<"$v"
  ((maj > 7 || (maj == 7 && min >= 7)))
}

_write_keys_atomically() {
  # $1 = authorized_keys path; stdin = new content. Preserves owner and mode 600.
  local path="$1" tmp owner
  owner="$TRINITY_MAINT_USER:$(id -gn "$TRINITY_MAINT_USER")"
  tmp="$(mktemp "$(dirname "$path")/.authorized_keys.XXXXXX")"
  cat >"$tmp"
  chmod 600 "$tmp"
  chown "$owner" "$tmp"
  mv -f "$tmp" "$path"
}

access_grant() {
  local key_in="" ttl=8h from="" agent="claude-code"
  while (($#)); do
    case "$1" in
      --pubkey) key_in="$2"; shift ;;
      --ttl) ttl="$2"; shift ;;
      --from) from="$2"; shift ;;
      --agent) agent="$2"; shift ;;
      *) die "access grant: unknown option $1" ;;
    esac
    shift
  done
  require_root
  require_cmd ssh-keygen getent
  [[ -n "$key_in" ]] || die "access grant requires --pubkey"
  getent passwd "$TRINITY_MAINT_USER" >/dev/null || die "maintenance user '$TRINITY_MAINT_USER' does not exist"
  [[ "$agent" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || die "--agent may contain only letters, digits, . _ -"
  if [[ -n "$from" ]]; then
    [[ "$from" =~ ^[0-9A-Fa-f.:/,*]+$ ]] || die "--from must be a comma-separated list of addresses/CIDRs"
  fi
  _sshd_supports_expiry || die "this sshd does not support expiry-time (needs OpenSSH >= 7.7); refusing a key without a hard expiry"

  local minutes
  minutes="$(_ttl_minutes "$ttl")"
  ((minutes >= 5 && minutes <= ACCESS_MAX_HOURS * 60)) || die "--ttl must be between 5m and ${ACCESS_MAX_HOURS}h"

  # Normalise the key to exactly: type base64 (comment dropped).
  local key_line type b64 rest
  if [[ -f "$key_in" ]]; then key_line="$(head -1 "$key_in")"; else key_line="$key_in"; fi
  read -r type b64 rest <<<"$key_line"
  case "$type" in
    ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa) ;;
    *) die "unsupported key type '$type' (private key? pass the .pub file)" ;;
  esac
  [[ "$b64" =~ ^[A-Za-z0-9+/=]+$ ]] || die "malformed public key"
  local tmpk fp bits
  tmpk="$(mktemp)"; on_exit "rm -f '$tmpk'"
  printf '%s %s\n' "$type" "$b64" >"$tmpk"
  fp="$(ssh-keygen -l -E sha256 -f "$tmpk" 2>/dev/null)" || die "ssh-keygen rejected the key"
  bits="$(awk '{print $1}' <<<"$fp")"
  if [[ "$type" == ssh-rsa ]] && ((bits < 3072)); then die "RSA keys must be >= 3072 bits"; fi
  fp="$(awk '{print $2}' <<<"$fp")"

  local keys session expiry_local expires_iso
  keys="$(_access_keys)"
  if [[ -f "$keys" ]] && grep -qF "$b64" "$keys"; then
    die "this key is already present in $keys (revoke it first or use a fresh key)"
  fi
  session="$(date -u +%Y%m%d%H%M%S)-$(openssl rand -hex 3)"
  # sshd interprets expiry-time in the system time zone.
  expiry_local="$(date -d "+${minutes} minutes" +%Y%m%d%H%M%S)"
  expires_iso="$(date -u -d "+${minutes} minutes" +%Y-%m-%dT%H:%M:%SZ)"

  local opts="expiry-time=\"${expiry_local}\",no-agent-forwarding,no-X11-forwarding,no-port-forwarding"
  [[ -n "$from" ]] && opts+=",from=\"${from}\""
  local entry="${opts} ${type} ${b64} ${ACCESS_MARK}:${session}:${agent}"

  local sshdir; sshdir="$(dirname "$keys")"
  install -d -m 700 -o "$TRINITY_MAINT_USER" -g "$(id -gn "$TRINITY_MAINT_USER")" "$sshdir"
  { [[ -f "$keys" ]] && cat "$keys"; printf '%s\n' "$entry"; } | _write_keys_atomically "$keys"
  grep -qF "${ACCESS_MARK}:${session}:" "$keys" || die "key was not written"

  # Audit record + baseline (Maintenance Mode enable sequence).
  local adir; adir="$(_access_dir)"; umask 077; mkdir -p "$adir"
  SESSION="$session" AGENT="$agent" FP="$fp" TYPE="$type" FROM="$from" TTL="$ttl" \
  GRANTED="$(utc_iso)" EXPIRES="$expires_iso" USER_V="$TRINITY_MAINT_USER" \
  HEAD_V="$(git_root rev-parse HEAD 2>/dev/null || echo unknown)" \
  BRANCH_V="$(git_root symbolic-ref --short -q HEAD 2>/dev/null || echo detached)" \
  EDGE="$(edge_identity 2>/dev/null || echo unknown)" OPERATOR="${SUDO_USER:-root}" \
  "$PYTHON" - >"$adir/$session.json" <<'PY'
import json, os
e = os.environ
print(json.dumps({
  "schema": "trinity.maintenance.access.v1", "session": e["SESSION"], "status": "ACTIVE",
  "agent": e["AGENT"], "operator": e["OPERATOR"], "maintenance_user": e["USER_V"],
  "key_type": e["TYPE"], "key_fingerprint": e["FP"], "allowed_from": e["FROM"] or None,
  "ttl": e["TTL"], "granted_at": e["GRANTED"], "expires_at": e["EXPIRES"],
  "start_git_head": e["HEAD_V"], "start_branch": e["BRANCH_V"], "start_edge_identity": e["EDGE"],
  "restrictions": ["expiry-time", "no-agent-forwarding", "no-X11-forwarding", "no-port-forwarding"],
}, indent=2))
PY
  ok "temporary access granted: session $session"
  log "  user:        $TRINITY_MAINT_USER (non-root)"
  log "  fingerprint: $fp"
  log "  expires:     $expires_iso (enforced by sshd)"
  [[ -n "$from" ]] && log "  from:        $from"
  log "  revoke now:  sudo trinity access revoke --session $session"
  _access_posture_warnings
  printf '%s\n' "$session"
}

_access_posture_warnings() {
  command -v sshd >/dev/null || return 0
  local t; t="$(sshd -T 2>/dev/null || true)"
  [[ -n "$t" ]] || return 0
  grep -qi '^permitrootlogin yes' <<<"$t" && warn "sshd allows root login with a password (PermitRootLogin yes); consider 'prohibit-password' or 'no'"
  grep -qi '^passwordauthentication yes' <<<"$t" && warn "sshd allows password authentication; key-only is safer"
  local allow; allow="$(awk 'tolower($1)=="allowusers"{ $1=""; print }' <<<"$t")"
  if [[ -n "${allow// /}" ]] && ! grep -qw "$TRINITY_MAINT_USER" <<<"$allow"; then
    warn "sshd AllowUsers does not include $TRINITY_MAINT_USER; the key will not work until it does"
  fi
  id -nG "$TRINITY_MAINT_USER" 2>/dev/null | grep -qw docker \
    && log "note: $TRINITY_MAINT_USER is in the docker group (technical capability, not authorization)"
  return 0
}

access_revoke() {
  local session="" all=0 expired=0 kill=0
  while (($#)); do
    case "$1" in
      --session) session="$2"; shift ;;
      --all) all=1 ;;
      --expired) expired=1 ;;
      --kill-sessions) kill=1 ;;
      *) die "access revoke: unknown option $1" ;;
    esac
    shift
  done
  require_root
  ((all + expired + (${#session} > 0) == 1)) || die "choose exactly one of --session ID, --all, --expired"
  [[ -z "$session" || "$session" =~ ^[0-9]{14}-[0-9a-f]{6}$ ]] || die "malformed session id"
  local keys adir now_local; keys="$(_access_keys)"; adir="$(_access_dir)"
  now_local="$(date +%Y%m%d%H%M%S)"
  [[ -f "$keys" ]] || { log "no authorized_keys file; nothing to revoke"; return 0; }

  local -a revoked=()
  local line sid exp
  local new; new="$(mktemp)"; on_exit "rm -f '$new'"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ${ACCESS_MARK}:([0-9]{14}-[0-9a-f]{6}): ]]; then
      sid="${BASH_REMATCH[1]}"
      exp="$(sed -n 's/^expiry-time="\([0-9]*\)".*/\1/p' <<<"$line")"
      if ((all)) || [[ "$sid" == "$session" ]] || { ((expired)) && [[ -n "$exp" && "$exp" < "$now_local" ]]; }; then
        revoked+=("$sid"); continue
      fi
    fi
    printf '%s\n' "$line"
  done <"$keys" >"$new"
  ((${#revoked[@]})) || { log "no matching maintenance keys present"; }
  _write_keys_atomically "$keys" <"$new"
  for sid in "${revoked[@]}"; do
    grep -qF "${ACCESS_MARK}:${sid}:" "$keys" && die "revocation failed for $sid: key still present"
  done

  if ((kill)); then
    warn "terminating ALL ssh sessions of $TRINITY_MAINT_USER (this includes any human session on that account)"
    pkill -TERM -u "$TRINITY_MAINT_USER" -x sshd 2>/dev/null || true
    pkill -TERM -u "$TRINITY_MAINT_USER" -f '^sshd: ' 2>/dev/null || true
  fi

  # Closure reports (Maintenance Mode disable sequence).
  for sid in "${revoked[@]}"; do
    local rec="$adir/$sid.json"
    [[ -f "$rec" ]] || { warn "no audit record for $sid"; continue; }
    local start_head
    start_head="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["start_git_head"])' "$rec")"
    local commits="" changed=""
    if [[ "$start_head" != unknown ]] && git_root cat-file -e "$start_head^{commit}" 2>/dev/null; then
      commits="$(git_root log --format='%h %s' "$start_head..HEAD" 2>/dev/null || true)"
      changed="$(git_root diff --name-only "$start_head" 2>/dev/null || true)"
    fi
    REC="$rec" REVOKED="$(utc_iso)" END_HEAD="$(git_root rev-parse HEAD 2>/dev/null || echo unknown)" \
    COMMITS="$commits" CHANGED="$changed" EDGE="$(edge_identity 2>/dev/null || echo unknown)" KILLED="$kill" \
    "$PYTHON" - <<'PY'
import json, os
e = os.environ
p = e["REC"]
r = json.load(open(p))
r.update({
  "status": "CLOSED", "revoked_at": e["REVOKED"], "key_removed_verified": True,
  "sessions_terminated": e["KILLED"] == "1",
  "end_git_head": e["END_HEAD"],
  "commits_during_session": [c for c in e["COMMITS"].splitlines() if c],
  "files_changed_since_start": [c for c in e["CHANGED"].splitlines() if c],
  "end_edge_identity": e["EDGE"],
  "edge_unchanged": e["EDGE"] == r.get("start_edge_identity"),
})
tmp = p + ".tmp"
open(tmp, "w").write(json.dumps(r, indent=2) + "\n")
os.replace(tmp, p)
print(f'closed {r["session"]}: commits={len(r["commits_during_session"])} files={len(r["files_changed_since_start"])} edge_unchanged={r["edge_unchanged"]}')
PY
  done
  ok "revoked: ${revoked[*]:-none}"
}

access_status() {
  local keys adir now_local; adir="$(_access_dir)"; now_local="$(date +%Y%m%d%H%M%S)"
  if getent passwd "$TRINITY_MAINT_USER" >/dev/null; then
    keys="$(_access_keys)"
    log "maintenance user: $TRINITY_MAINT_USER (groups: $(id -nG "$TRINITY_MAINT_USER"))"
    if [[ -r "$keys" ]]; then
      local line sid exp state n=0
      while IFS= read -r line; do
        [[ "$line" =~ ${ACCESS_MARK}:([0-9]{14}-[0-9a-f]{6}):([A-Za-z0-9._-]+) ]] || continue
        sid="${BASH_REMATCH[1]}"
        exp="$(sed -n 's/^expiry-time="\([0-9]*\)".*/\1/p' <<<"$line")"
        if [[ -n "$exp" && "$exp" < "$now_local" ]]; then state="EXPIRED (sshd refuses it; clean up with --expired)"; else state="ACTIVE until $exp (local time)"; fi
        printf '  %s agent=%s %s\n' "$sid" "${BASH_REMATCH[2]}" "$state"
        n=$((n + 1))
      done <"$keys"
      ((n)) || log "no maintenance keys installed (access is OFF)"
      local other
      other="$(grep -cv -e "${ACCESS_MARK}:" -e '^[[:space:]]*$' -e '^#' "$keys" || true)"
      log "other (permanent) keys on $TRINITY_MAINT_USER: ${other:-0}"
    else
      log "authorized_keys not readable here (run with sudo for full status)"
    fi
  else
    warn "maintenance user $TRINITY_MAINT_USER does not exist"
  fi
  if [[ -d "$adir" ]]; then
    log "audit records: $adir"
    local f
    for f in "$adir"/*.json; do
      [[ -f "$f" ]] || continue
      "$PYTHON" -c 'import json,sys; r=json.load(open(sys.argv[1])); print("  {session} {status} agent={agent} fp={key_fingerprint} granted={granted_at} expires={expires_at}".format(**r))' "$f"
    done
  fi
  [[ "$(id -u)" == 0 ]] && _access_posture_warnings
  return 0
}

access_main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    grant)  access_grant "$@" ;;
    revoke) access_revoke "$@" ;;
    status) access_status ;;
    ""|-h|--help|help) access_usage ;;
    *) die "access: unknown command $sub" ;;
  esac
}
