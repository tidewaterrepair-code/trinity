# Giving Claude access to the VPS

Two routes. Both follow `docs/trinity/TRINITY-MAINTENANCE-MODE.md`: access is explicit,
temporary, non-root, audited and revocable. Neither one authorizes production changes;
the Builder Rules still apply (Edge never touched, production is not a test sandbox).

## Route A (recommended): run Claude Code on the VPS with Remote Control

A Claude Code cloud session runs in an isolated container, and its network policy does not
allow outbound SSH. The reliable route is to run Claude Code *on the VPS*, as the
non-root maintenance user, and drive it from the Claude app through Remote Control.

On the VPS:

```bash
sudo trinity protect                      # baseline + UI snapshot + proven backup first
sudo -iu blackwell                        # non-root maintenance user
cd ~/trinity-maintenance                  # a maintenance worktree, not /opt/blackwell
claude remote-control                     # this session appears in the Claude Code app
```

Stop it with Ctrl-C when the maintenance session ends. Docker-group membership of
`blackwell` is technical capability, not authorization (Builder Rule 23).

## Route B: temporary SSH key (for an SSH-capable agent)

```bash
sudo trinity access grant --pubkey agent.pub --ttl 8h --agent claude-code [--from AGENT_IP]
# ... maintenance ...
sudo trinity access revoke --session <SESSION-ID>
```

- The key sits on `blackwell` only, with `expiry-time` enforced by sshd (max 72h),
  `no-agent-forwarding`, `no-X11-forwarding`, `no-port-forwarding`.
- `trinity access status` shows active and expired grants and warns about risky sshd settings
  (`PermitRootLogin yes`, password authentication, `AllowUsers` excluding `blackwell`).
- Revocation verifies the key is gone and writes a closure record: commits and files changed
  during the session, end commit, and whether Edge stayed unchanged.
- `--kill-sessions` also terminates open SSH sessions of `blackwell`, including any human
  session on that account.

A cloud session can only use Route B if the environment's network policy allows outbound
SSH to the VPS; the default policy does not.

## What to send back if neither route is available

The read-only discovery summary is designed to be safe to share (no secret values, scanned):

```bash
sudo trinity discover
sudo cat /home/blackwell/trinity-maintenance/installer/*-discover/summary.txt
```
