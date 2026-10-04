#!/usr/bin/env python3
"""Data helpers for the Trinity installer (stdlib only).

Shell collects raw facts; this module redacts, compares and assembles them.
Nothing here opens network connections or reads secret file contents.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys

SECRET_PATTERNS = [
    ("connection string with password", re.compile(r"\b[a-z][a-z0-9+.-]*://[^/\s:@\"']+:[^@\s\"']+@", re.I)),
    ("private key block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("OAuth token field", re.compile(r"\"(access_token|refresh_token|id_token)\"\s*:\s*\"[^\"]{8,}")),
    ("OpenAI-style key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("GitHub token", re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")),
    ("Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("Telegram bot token", re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b")),
    ("bearer credential", re.compile(r"\bAuthorization:\s*Bearer\s+[A-Za-z0-9._~+/=-]{12,}", re.I)),
    ("bcrypt hash", re.compile(r"\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}")),
    ("password assignment", re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|API_KEY)=(?!CHANGE_ME\b)[^\s\"'$]{6,}", re.I)),
]


def scan_text(text: str) -> list[str]:
    hits = []
    for label, pattern in SECRET_PATTERNS:
        if pattern.search(text):
            hits.append(label)
    return hits


def cmd_scan_secrets(args: argparse.Namespace) -> int:
    bad = 0
    for name in args.files:
        text = pathlib.Path(name).read_text(errors="replace")
        hits = scan_text(text)
        if hits:
            bad += 1
            print(f"secret scan: {os.path.basename(name)}: {', '.join(sorted(set(hits)))}", file=sys.stderr)
    return 1 if bad else 0


def _env_names(env):
    out = []
    for item in env or []:
        out.append(item.split("=", 1)[0])
    return sorted(out)


def cmd_sanitize_inspect(args: argparse.Namespace) -> int:
    """Reduce `docker inspect` output to identity facts. Env values are dropped."""
    data = json.load(sys.stdin)
    out = []
    for c in data:
        cfg = c.get("Config") or {}
        state = c.get("State") or {}
        host = c.get("HostConfig") or {}
        labels = cfg.get("Labels") or {}
        out.append({
            "name": (c.get("Name") or "").lstrip("/"),
            "id": c.get("Id"),
            "image_id": c.get("Image"),
            "image_ref": cfg.get("Image"),
            "created": c.get("Created"),
            "state": state.get("Status"),
            "started_at": state.get("StartedAt"),
            "health": (state.get("Health") or {}).get("Status"),
            "restart_count": c.get("RestartCount"),
            "user": cfg.get("User"),
            "env_names": _env_names(cfg.get("Env")),
            "read_only_rootfs": host.get("ReadonlyRootfs"),
            "privileged": host.get("Privileged"),
            "cap_add": host.get("CapAdd"),
            "cap_drop": host.get("CapDrop"),
            "security_opt": host.get("SecurityOpt"),
            "network_mode": host.get("NetworkMode"),
            "port_bindings": host.get("PortBindings"),
            "networks": sorted((c.get("NetworkSettings") or {}).get("Networks", {}).keys()),
            "mounts": [
                {k: m.get(k) for k in ("Type", "Name", "Source", "Destination", "RW", "Mode")}
                for m in c.get("Mounts") or []
            ],
            "docker_socket_mounted": any(
                (m.get("Source") or "").endswith("docker.sock") for m in c.get("Mounts") or []
            ),
            "compose": {
                k.split("com.docker.compose.", 1)[1]: v
                for k, v in labels.items()
                if k.startswith("com.docker.compose.")
                and k.split("com.docker.compose.", 1)[1]
                in ("project", "service", "project.working_dir", "project.config_files", "config-hash", "image", "version")
            },
        })
    json.dump(out, sys.stdout, indent=2, sort_keys=True)
    print()
    return 0


def read_manifest(path: str) -> dict[str, str]:
    """Parse `sha256sum` output into {relative_path: digest}."""
    result = {}
    for line in pathlib.Path(path).read_text().splitlines():
        if not line.strip():
            continue
        digest, name = line.split(None, 1)
        name = name.lstrip("*")
        if name.startswith("./"):
            name = name[2:]
        result[name] = digest
    return result


def compare_manifests(a: dict[str, str], b: dict[str, str]) -> dict:
    same = sorted(k for k in a if k in b and a[k] == b[k])
    changed = sorted(k for k in a if k in b and a[k] != b[k])
    only_a = sorted(k for k in a if k not in b)
    only_b = sorted(k for k in b if k not in a)
    return {"identical": same, "changed": changed, "only_left": only_a, "only_right": only_b}


def cmd_compare(args: argparse.Namespace) -> int:
    cmp = compare_manifests(read_manifest(args.left), read_manifest(args.right))
    cmp["left"] = args.left_label
    cmp["right"] = args.right_label
    cmp["match"] = not (cmp["changed"] or cmp["only_left"] or cmp["only_right"])
    if args.brief:
        cmp["identical"] = len(cmp["identical"])
    json.dump(cmp, sys.stdout, indent=2)
    print()
    if args.strict and not cmp["match"]:
        return 1
    return 0


LEDGER_INSERT = re.compile(r"INSERT\s+INTO\s+(?:blackwell\.)?schema_migrations", re.I)


def cmd_migrations(args: argparse.Namespace) -> int:
    """Compare source migration files with the database ledger.

    Source file count and ledger rows are different quantities: only files that
    insert into schema_migrations produce a ledger row.
    """
    import hashlib

    src = sorted(pathlib.Path(args.migrations_dir).glob("*.sql")) if args.migrations_dir else []
    files = []
    for p in src:
        body = p.read_bytes()
        files.append({
            "file": p.name,
            "version": p.name[:4],
            "sha256": hashlib.sha256(body).hexdigest(),
            "writes_ledger": bool(LEDGER_INSERT.search(body.decode("utf-8", "replace"))),
        })
    ledger = []
    if args.ledger and os.path.exists(args.ledger):
        ledger = [line.strip() for line in pathlib.Path(args.ledger).read_text().splitlines() if line.strip()]
    expected = [f["version"] for f in files if f["writes_ledger"]]
    latest_file = files[-1]["version"] if files else None
    report = {
        "source_file_count": len(files),
        "source_ledger_writing_count": len(expected),
        "source_latest_file": latest_file,
        "ledger_row_count": len(ledger),
        "ledger_latest": ledger[-1] if ledger else None,
        "ledger_versions": ledger,
        "pending_ledger_versions": [v for v in expected if v not in ledger] if ledger else None,
        "ledger_versions_without_source": [v for v in ledger if v not in {f["version"] for f in files}] if files else None,
        "ledger_matches_source_exactly": (ledger == expected) if (ledger and files) else None,
        "files": files,
    }
    json.dump(report, sys.stdout, indent=2)
    print()
    return 0


def _load(path: pathlib.Path, default=None):
    if not path.exists():
        return default
    text = path.read_text(errors="replace")
    if path.suffix == ".json":
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {"unparsed": text[:2000]}
    return [line for line in text.splitlines() if line.strip()]


def cmd_assemble(args: argparse.Namespace) -> int:
    """Combine raw discovery files into manifest.json and summary.txt."""
    raw = pathlib.Path(args.raw)
    out = pathlib.Path(args.out)
    manifest = {"schema": "trinity.installer.discovery.v1", "generated_at": args.generated_at}
    for p in sorted(raw.iterdir()):
        key = p.stem.replace("-", "_")
        manifest[key] = _load(p)
    manifest["safety"] = {
        "environment_values_collected": False,
        "secret_file_contents_collected": False,
        "database_row_contents_collected": False,
        "ssh_key_contents_collected": False,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    lines = ["TRINITY DISCOVERY SUMMARY", f"generated: {args.generated_at}", ""]

    def section(title):
        lines.append("")
        lines.append(f"== {title}")

    host = manifest.get("host") or {}
    if isinstance(host, dict):
        section("Host")
        for k in ("hostname", "os", "kernel", "docker", "compose", "disk_free_root", "memory"):
            lines.append(f"  {k}: {host.get(k)}")

    repos = manifest.get("git") or []
    section("Source checkouts")
    if isinstance(repos, list) and repos and isinstance(repos[0], dict):
        for r in repos:
            lines.append(f"  {r.get('path')}")
            lines.append(f"    branch={r.get('branch')} head={r.get('head')} dirty_files={len(r.get('dirty') or [])} untracked={len(r.get('untracked') or [])}")
            for k, v in (r.get("known_commits") or {}).items():
                lines.append(f"    {k}: {v}")
    else:
        lines.append("  none found")

    edge = manifest.get("edge") or {}
    section("Edge fence")
    if isinstance(edge, dict):
        lines.append(f"  status: {edge.get('fence')}")
        lines.append(f"  id: {edge.get('id')}")
        lines.append(f"  image: {edge.get('image')}")
        lines.append(f"  started: {edge.get('started_at')}")

    ui = manifest.get("ui") or {}
    section("Served UI")
    if isinstance(ui, dict):
        lines.append(f"  container: {ui.get('container')} image: {ui.get('image_id')}")
        lines.append(f"  served files: {ui.get('served_file_count')} bytes: {ui.get('served_bytes')}")
        cmp = ui.get("served_vs_source") or {}
        if cmp:
            lines.append(
                "  vs source checkout: identical={} changed={} only_served={} only_source={}".format(
                    len(cmp.get("identical", [])), len(cmp.get("changed", [])),
                    len(cmp.get("only_left", [])), len(cmp.get("only_right", [])))
            )
            for name in cmp.get("changed", [])[:20]:
                lines.append(f"    changed: {name}")
            for name in cmp.get("only_left", [])[:20]:
                lines.append(f"    served only (not in checkout): {name}")

    mig = manifest.get("migrations") or {}
    section("Schema")
    if isinstance(mig, dict):
        for k in ("source_file_count", "source_ledger_writing_count", "source_latest_file",
                  "ledger_row_count", "ledger_latest", "pending_ledger_versions", "ledger_matches_source_exactly"):
            lines.append(f"  {k}: {mig.get(k)}")

    roles = manifest.get("db_roles") or []
    if isinstance(roles, list) and roles:
        section("Database roles (attributes only)")
        for r in roles:
            lines.append(f"  {r}")
    sessions = manifest.get("db_sessions") or []
    if isinstance(sessions, list) and sessions:
        section("Connected database identities")
        for r in sessions:
            lines.append(f"  {r}")

    containers = manifest.get("containers") or []
    if isinstance(containers, list) and containers:
        section("Containers")
        for c in containers:
            if not isinstance(c, dict):
                continue
            flags = []
            if not c.get("read_only_rootfs"):
                flags.append("writable-rootfs")
            if c.get("privileged"):
                flags.append("PRIVILEGED")
            if c.get("docker_socket_mounted"):
                flags.append("DOCKER-SOCKET")
            if c.get("user") in (None, "", "0", "root"):
                flags.append("runs-as-root?")
            lines.append(f"  {c.get('name')}: {c.get('state')}/{c.get('health')} image={str(c.get('image_id'))[:19]} {' '.join(flags)}")

    exposure = manifest.get("exposure") or []
    if exposure:
        section("Public exposure probe (GET only)")
        for line in exposure if isinstance(exposure, list) else [exposure]:
            lines.append(f"  {line}")

    secrets = manifest.get("secret_files") or []
    if secrets:
        section("Secret files (metadata only)")
        for line in secrets if isinstance(secrets, list) else [secrets]:
            lines.append(f"  {line}")

    lines.append("")
    lines.append("Labels: this report is VERIFIED only for the moment it was generated. It records")
    lines.append("no environment values, secret contents, database rows or key material.")
    (out / "summary.txt").write_text("\n".join(lines) + "\n")
    return 0


def cmd_git_report(args: argparse.Namespace) -> int:
    """Assemble one checkout's facts (from small text files) into JSON."""
    d = pathlib.Path(args.dir)

    def lines(name):
        p = d / name
        return [x for x in p.read_text(errors="replace").splitlines() if x.strip()] if p.exists() else []

    known = {}
    for line in lines("known.txt"):
        label, state = line.rsplit(" ", 1)
        known[label] = state
    report = {
        "path": args.path,
        "head": (lines("head.txt") or [None])[0],
        "branch": (lines("branch.txt") or [None])[0],
        "describe": (lines("describe.txt") or [None])[0],
        "remotes": lines("remotes.txt"),
        "branches": lines("branches.txt"),
        "worktrees": lines("worktrees.txt"),
        "stash_count": len(lines("stash.txt")),
        "dirty": lines("dirty.txt"),
        "untracked": lines("untracked.txt"),
        "known_commits": known,
    }
    json.dump(report, sys.stdout, indent=2)
    print()
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="trinity_helper")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("scan-secrets")
    p.add_argument("files", nargs="+")
    p.set_defaults(fn=cmd_scan_secrets)

    p = sub.add_parser("sanitize-inspect")
    p.set_defaults(fn=cmd_sanitize_inspect)

    p = sub.add_parser("compare")
    p.add_argument("left")
    p.add_argument("right")
    p.add_argument("--left-label", default="left")
    p.add_argument("--right-label", default="right")
    p.add_argument("--strict", action="store_true")
    p.add_argument("--brief", action="store_true", help="count identical files instead of listing them")
    p.set_defaults(fn=cmd_compare)

    p = sub.add_parser("migrations")
    p.add_argument("--migrations-dir")
    p.add_argument("--ledger")
    p.set_defaults(fn=cmd_migrations)

    p = sub.add_parser("assemble")
    p.add_argument("--raw", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--generated-at", required=True)
    p.set_defaults(fn=cmd_assemble)

    p = sub.add_parser("git-report")
    p.add_argument("--dir", required=True)
    p.add_argument("--path", required=True)
    p.set_defaults(fn=cmd_git_report)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
