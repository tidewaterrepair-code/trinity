# THE BLACK WELL TRINITY — Installer

Installer and maintenance toolkit for THE BLACK WELL TRINITY
([`the-black-well`](https://github.com/tidewaterrepair-code/the-black-well)).

It is built for the situation described in the complete-build continuation map:
a VPS that is **already partially built** and running a Command Cathedral UI you want to keep.
On an existing installation it **changes nothing** until you explicitly ask it to.

| Guarantee | How it is enforced |
|---|---|
| Edge (`blackwell-edge`) is never touched | every Compose call goes through `compose_safe`, which refuses `edge`, `down`, `rm`, `restart`, `-v`, `--force-recreate`, and `up` without `--no-deps`; mutating commands record Edge's identity before and after and fail if it changed |
| Production is read-only by default | `discover`, `protect`, `backup`, `provisioning export` and `stage` only read; database sessions run with `default_transaction_read_only=on` |
| No secrets in reports | reports keep env-var *names*, never values; secret files are recorded as path/mode/owner/size only; every report is scanned for credentials, DSNs, keys, tokens and hashes and deleted if anything is found |
| Backups are proven, not assumed | each database dump is restored into a disposable, network-less PostgreSQL and its ledger and per-table row counts are compared |
| Install never runs over an installation | `install` refuses if a checkout, `blackwell-*` container, database volume or `/etc/blackwell` exists |

## 1. Protect what is on the VPS now (do this first)

On the VPS, as a sudo-capable user:

```bash
git clone https://github.com/tidewaterrepair-code/trinity.git ~/trinity-installer
cd ~/trinity-installer
git checkout claude/epic-turing-9su4ep
sudo ./install.sh --guard
```

Expected result: a `TRINITY PROTECTED` block listing

- a **discovery report** (`summary.txt`): checkouts and dirty work, which of the known
  continuation commits are present, Docker runtime identity, Edge fence, **served UI vs
  source** (which files differ), migration ledger vs source, database role attributes,
  connected identities, table/function grants, secret metadata, public exposure;
- a **UI snapshot**: the exact files the web container serves (hash-verified), the exact
  running web image (pinned tag + `docker save`), `apps/web` source including untracked
  refinements, all read-only with `SHA256SUMS`;
- a **provisioning profile**: the database grants as installed today, as SQL (no passwords);
- a **backup** with `restore proof: PASS`;
- `--guard` installs an hourly read-only check that logs `UI DRIFT` to the journal if the
  served UI ever changes (`journalctl -t trinity-ui-guard`).

Then, still on the VPS, write the secrets to a separate encrypted file (asks for a passphrase):

```bash
sudo trinity backup secrets --out /root/trinity-secrets-$(date -u +%Y%m%d).enc
```

Everything the installer writes is root-only (mode 700/600), because backups contain the
database. To copy it off the VPS, first package it for your login user, on the VPS:

```bash
sudo tar -C /home/blackwell/trinity-maintenance -cf ~/trinity-protect.tar installer
sudo cp /root/trinity-secrets-*.enc ~/
sudo chown "$USER": ~/trinity-protect.tar ~/trinity-secrets-*.enc
chmod 600 ~/trinity-protect.tar ~/trinity-secrets-*.enc
```

Then from **your own computer** (replace `you@YOUR-VPS` with your login and server address):

```bash
scp you@YOUR-VPS:trinity-protect.tar you@YOUR-VPS:'trinity-secrets-*.enc' .
```

Afterwards delete the two copies in your VPS home directory. Keep the `.enc` file apart from the backup.

## 2. The Command Cathedral UI

```bash
trinity ui verify                 # live UI vs latest snapshot (exit 1 on drift)
trinity ui list                   # all snapshots
trinity ui export                 # one .tar for off-host safekeeping
sudo trinity ui restore --snapshot /home/blackwell/trinity-maintenance/installer/ui-snapshots/<STAMP>
```

`restore` first snapshots the current UI (so the restore is itself reversible), reloads the
preserved image from the snapshot if it was deleted, retags it to the name Compose uses,
recreates **only** `blackwell-web` with `--no-deps --no-build`, then proves the served bytes
match the snapshot and Edge is unchanged.

## 3. Temporary maintenance access (how Claude gets onto the VPS)

Implements the enable/disable sequence in `docs/trinity/TRINITY-MAINTENANCE-MODE.md`.

```bash
sudo trinity access grant --pubkey /path/to/claude_key.pub --ttl 8h --agent claude-code
sudo trinity access status
sudo trinity access revoke --session <SESSION-ID>
```

- one key on the non-root `blackwell` user, never root;
- `expiry-time` written into `authorized_keys`, so **sshd itself** refuses the key after the TTL (max 72h);
- no agent, X11 or port forwarding; optional `--from CIDR`;
- an audit record with fingerprint, start commit and Edge identity; revocation verifies the
  key is gone and records commits/files changed during the session and whether Edge stayed unchanged.

See [docs/VPS-ACCESS.md](docs/VPS-ACCESS.md) for the remaining one-time setting needed so a
Claude Code cloud session can actually reach your VPS.

## 4. Candidates and upgrades (scratch only)

```bash
trinity stage --ref <commit-sha> --provisioning <discover-dir>/runtime-provisioning.sql
```

Extracts the candidate with `git archive` (production checkout untouched), applies the full
migration chain to a scratch database and checks the ledger exactly, restores the latest
proven backup into a second scratch database and applies only the pending migrations, then
compares the resulting privilege profiles. The report lists what activation *would* change
(including a hard flag if Edge files change). It does not activate anything.

## 5. New host or disaster recovery

```bash
# rebuild from a backup (+ decrypted secrets tar) on a clean VPS
sudo ./install.sh --fresh --from-backup ./installer/backups/<STAMP> --secrets-tar ./secrets.tar

# brand-new install (needs the production provisioning profile to start runtime services)
sudo ./install.sh --fresh --provisioning ./runtime-provisioning.sql
```

Fresh install: clones the pinned source commit, generates every secret into root-owned files
(never printed), starts PostgreSQL, bootstraps the external roles, applies the full migration
chain and verifies the ledger exactly, applies the provisioning profile, activates the service
roles from their DSN files, creates the Sovereign operator, builds images per service, starts
services in dependency order and waits for health, and starts Edge only because none existed.
One-time credentials go to `/root/trinity-initial-credentials.txt` (mode 600).

Not automated, by design: model OAuth login, DNS, Telegram tokens.

## Commands

```
trinity preflight | protect | discover | ui ... | backup | backup secrets
        provisioning export|compare | stage | access grant|revoke|status | install
```

Global options: `--yes` (non-interactive confirmations), `--root DIR` (default `/opt/blackwell`),
`--state-dir DIR` (default `/home/blackwell/trinity-maintenance/installer`).
Persistent settings can go in `/etc/trinity-installer.conf` (`KEY=value`, no secrets).

## Tests

```bash
python3 -m unittest tests/test_helper.py      # redaction, manifest compare, ledger logic
tests/integration.sh                          # full simulated-VPS run (needs Docker; destructive to the test host)
```

Evidence from the run that produced this version is in
[docs/ACCEPTANCE-EVIDENCE.md](docs/ACCEPTANCE-EVIDENCE.md).
