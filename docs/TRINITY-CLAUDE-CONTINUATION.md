# Trinity — Claude continuation checkpoint

Written 2026-10-04. Read with the complete-build continuation map and
`the-black-well/docs/trinity/TRINITY-BUILDER-RULES.md`.

## State labels

- **VERIFIED (this session, sandbox)**: established by commands run in a disposable sandbox host.
- **SOURCE**: read from `tidewaterrepair-code/the-black-well` on GitHub.
- **UNVERIFIED**: about the real VPS; nothing here was observed on it.

## What exists now

| Item | State |
|---|---|
| Installer toolkit: this repo, branch `claude/epic-turing-9su4ep` | VERIFIED in sandbox (see ACCEPTANCE-EVIDENCE.md) |
| Latest source continuation: `the-black-well` branch `agent/trinity-completion-20260930` @ `445267c` | SOURCE |
| Golden tag `trinity-v12l-0048-closed` @ `edd4f0f` | SOURCE |
| `fce269d` (native seats) and `7bf1dfc` are ancestors of `445267c` | SOURCE |
| Branches `feature/trinity-second-brain-v10` and `agent/openclaw-trinity-builder` both end at `86f4bcd`, an ancestor of `445267c` | SOURCE |
| `main` @ `f2de1da` is an old UI-only line (76 files), not the deploy branch | SOURCE |
| Real VPS (`srv1883163`, `/opt/blackwell`): installed commit, dirty work, served UI, schema, roles | **UNVERIFIED (no access from cloud session)** |

## Findings that change what the next builder should do

1. The service roles created by migrations are `NOLOGIN`; LOGIN/password activation and the
   `blackwell_runtime` core-table grants were done operationally and are **not** in source.
   `trinity provisioning export` captures the real grants from production as SQL; `stage`
   proves whether fresh and upgraded schemas produce identical profiles.
   Sandbox result: fresh chain vs 0048→0051 upgrade give **identical** migration-created grants.
2. The DSN-file→role mapping in `lib/install.sh` (`INSTALL_ROLE_FILES`) is derived from
   compose variable names. A real discovery run lists the role each production DSN file
   uses (`dsn-roles.txt`, role names only); confirm the mapping against it.
3. `repository_ingestor` (apt) and `embedder` (Hugging Face model bake) could not be built in
   the sandbox because those hosts are blocked by the sandbox egress policy. They are not
   installer defects, but their builds are unproven here.

## Exact next actions

1. **Jimmy, on the VPS:** follow README section 1 (`sudo ./install.sh --guard`, then
   `sudo trinity backup secrets ...`, then copy off-host). Production is not modified.
2. Give a maintenance session access (docs/VPS-ACCESS.md, Route A: `claude remote-control`
   as `blackwell`), or share `summary.txt` from the discovery run.
3. With the real discovery: reconcile installed commit vs `445267c`, dirty files, served UI vs
   source, ledger (expect through 0048 or later), and grants. Record in the-black-well
   `TRINITY-CURRENT-STATE-AUDIT.md`.
4. `trinity stage --ref 445267c... --provisioning <discover>/runtime-provisioning.sql` on the VPS:
   proves the 0049–0051 upgrade and provisioning in scratch against the real backup.
5. Then continue P1 in the-black-well (operator gate / session / CSRF / tenant binding before
   model calls) per continuation map §5.

## Not done, and not authorized

- No production activation, migration, restart or Edge change. Activation needs Jimmy's decision
  on a staged, reviewed package.
- No capability gate C0–C11 is claimed closed by this work. This installer serves C0
  (baseline, recovery, UI preservation) and C10 (`recovery`, `safe_update_system`) partially.
