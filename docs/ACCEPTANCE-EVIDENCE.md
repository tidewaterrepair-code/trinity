# Acceptance evidence — Trinity installer

Environment: disposable sandbox host (Ubuntu 24.04, Docker 29.6.2, Compose 5.3.1, OpenSSH 9.6p1),
2026-10-04. Source under test: `the-black-well` @ `445267c03cba59e4538b80663b0a7ed1926a0956`.
**Nothing below was observed on the real VPS.** Real-VPS state remains UNVERIFIED.

## Integration suite (`tests/integration.sh`, run 2026-10-04T18:42Z, exit 0)

```
PASS fresh install: 51 migration files, 38 ledger rows, latest 0051
PASS install refuses to run over an existing installation
PASS Sovereign operator bootstrapped; credentials only in root-only file
PASS protect: discovery + UI snapshot + provisioning export + backup with restore proof PASS
PASS discovery reports the uncommitted UI change that is not being served
PASS UI snapshot checksums verify
PASS ui verify detects a rebuilt, changed UI
PASS ui restore returns the exact preserved UI bytes
PASS restore reloads a deleted preserved image from its saved tar
PASS Edge identity unchanged across protect/restore
PASS granted key logs in as non-root blackwell
PASS sshd refuses the key once expiry-time has passed
PASS revocation removes the key and writes a closure record
PASS stage: golden 0048 database upgrades to 0051 in scratch; fresh and upgrade privilege profiles identical
PASS secret scan clean across all reports
ALL INTEGRATION CHECKS PASSED
```

In the suite, "Edge" is a stand-in container named `blackwell-edge`; the check proves the
installer never recreated or restarted it.

## Additional runs

| Check | Result |
|---|---|
| Fresh-chain ledger | 51 files / 38 ledger rows / latest 0051, matching the VPS scratch result recorded in `docs/trinity/CONTINUATION-20260930.md` |
| Full fresh install with services started (`TRINITY_INSTALL_SKIP="repository_ingestor embedder"`, sandbox test-fixture grants) | api, worker, dispatcher, codex_bridge, operator-auth, admission-authorizer, admission-executor, operator-admission-broker, web and Edge (real Caddy) **healthy**; vox image download blocked (reported as not healthy) |
| Sovereign login through web → operator-auth on its provisioned role | correct password + origin: **200** with `__Host-blackwell_operator` cookie; wrong password: **401**; foreign Origin: **403** |
| `protect` on that real stack | discovery, UI snapshot, provisioning profile (679 grants), backup, restore proof PASS (131 tables, ledger 38), Edge unchanged |
| Recovery install from backup + decrypted secrets tar onto a wiped host | source restored at the backed-up commit with its 2 uncommitted/untracked files, data/ restored, ledger matches backup, production DSN reused and the runtime role authenticates with it |
| Backup under concurrent writes (inserts during dump) | restore proof PASS with restored counts inside the before/after window (tenants 12 → 13 restored → 20) |
| Backup with insufficient disk | refused before writing ("need ~2134 MiB, have 63 MiB"), no partial directory |
| Encrypted secrets bundle | AES-256-CBC/PBKDF2 (600k iterations) round-trips; wrong passphrase rejected; file mode 0400 |
| Unit tests (`python3 -m unittest tests/test_helper.py`) | OK (7 tests: redaction patterns, safe metadata, manifest compare, strict exit codes, ledger-vs-file counts, env-value stripping, DSN role without password) |
| `shellcheck -x -S warning` on all scripts | clean |

## Not verified here (and why)

| Item | Reason |
|---|---|
| `repository_ingestor` and `embedder` image builds | sandbox egress policy blocks `deb.debian.org` (apt) and `huggingface.co` (model bake) with HTTP 403 |
| `vox` start | sandbox egress policy blocks the ghcr.io blob download |
| Real public HTTPS / ACME through Edge | sandbox has no public DNS/ports |
| Anything about the real VPS | no access from the cloud session (outbound SSH blocked); see docs/VPS-ACCESS.md |

Sandbox-only adjustments that are not part of the installer: a local shadow of
`python:3.13-slim-bookworm` that trusts the sandbox proxy CA (so `pip` could build images), and
broad runtime grants used as an explicitly labeled test fixture to exercise service start-up.
Real installs use the production profile from `trinity provisioning export`.
