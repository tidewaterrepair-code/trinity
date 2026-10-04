"""Unit tests for lib/trinity_helper.py (stdlib unittest; no Docker needed)."""

import io
import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "lib"))
import trinity_helper as h  # noqa: E402


class SecretScan(unittest.TestCase):
    def test_detects_secret_material(self):
        samples = {
            "dsn": "postgresql://blackwell_runtime:s3cretpass@postgres:5432/blackwell",
            "pem": "-----BEGIN OPENSSH PRIVATE KEY-----",
            "oauth": '{"refresh_token": "abcdefgh12345678"}',
            "openai": "sk-" + "A" * 30,
            "github": "ghp_" + "a" * 36,
            "bearer": "Authorization: Bearer abcdefghijklmnop",
            "bcrypt": "$2a$14$" + "a" * 53,
            "assign": "POSTGRES_PASSWORD=hunter2hunter2",
        }
        for name, text in samples.items():
            with self.subTest(name):
                self.assertTrue(h.scan_text(text), name)

    def test_allows_safe_metadata(self):
        safe = "\n".join([
            "/opt/blackwell/secrets/blackwell_database_url mode=644 owner=root:root size=103",
            "POSTGRES_PASSWORD",
            "POSTGRES_PASSWORD=CHANGE_ME",
            "DATABASE_URL_FILE=/run/secrets/blackwell_database_url",
            "sha256:219978e4a0dce28ea0540dbee7fe2f272245eb2eeeb2de2f2f584d525aba0de4",
            "https://github.com/tidewaterrepair-code/the-black-well.git",
            "blackwell_runtime login=true super=false bypassrls=false",
        ])
        self.assertEqual(h.scan_text(safe), [])


class Manifests(unittest.TestCase):
    def _write(self, d, name, rows):
        p = pathlib.Path(d) / name
        p.write_text("".join(f"{dig}  {path}\n" for dig, path in rows))
        return str(p)

    def test_compare_reports_each_class(self):
        with tempfile.TemporaryDirectory() as d:
            a = self._write(d, "a", [("1" * 64, "index.html"), ("2" * 64, "app.js"), ("3" * 64, "only-a.css")])
            b = self._write(d, "b", [("1" * 64, "./index.html"), ("9" * 64, "app.js"), ("4" * 64, "only-b.js")])
            cmp = h.compare_manifests(h.read_manifest(a), h.read_manifest(b))
        self.assertEqual(cmp["identical"], ["index.html"])
        self.assertEqual(cmp["changed"], ["app.js"])
        self.assertEqual(cmp["only_left"], ["only-a.css"])
        self.assertEqual(cmp["only_right"], ["only-b.js"])

    def test_strict_compare_exit_code(self):
        with tempfile.TemporaryDirectory() as d:
            a = self._write(d, "a", [("1" * 64, "index.html")])
            b = self._write(d, "b", [("2" * 64, "index.html")])
            with redirect_stdout(io.StringIO()):
                self.assertEqual(h.main(["compare", a, a, "--strict"]), 0)
                self.assertEqual(h.main(["compare", a, b, "--strict"]), 1)


class Migrations(unittest.TestCase):
    def test_ledger_rows_are_not_file_counts(self):
        with tempfile.TemporaryDirectory() as d:
            mig = pathlib.Path(d) / "m"
            mig.mkdir()
            (mig / "0001_a.sql").write_text("INSERT INTO blackwell.schema_migrations VALUES ('0001');")
            (mig / "0002_b.sql").write_text("-- no ledger row")
            (mig / "0003_c.sql").write_text("insert into schema_migrations values ('0003');")
            ledger = pathlib.Path(d) / "ledger.txt"
            ledger.write_text("0001\n")
            buf = io.StringIO()
            with redirect_stdout(buf):
                h.main(["migrations", "--migrations-dir", str(mig), "--ledger", str(ledger)])
            r = json.loads(buf.getvalue())
        self.assertEqual(r["source_file_count"], 3)
        self.assertEqual(r["source_ledger_writing_count"], 2)
        self.assertEqual(r["pending_ledger_versions"], ["0003"])
        self.assertFalse(r["ledger_matches_source_exactly"])


class SanitizeInspect(unittest.TestCase):
    def test_env_values_are_dropped(self):
        inspect = [{
            "Name": "/blackwell-api", "Id": "abc", "Image": "sha256:1",
            "Config": {"Image": "blackwell-api", "Env": ["DATABASE_URL=postgresql://u:p@h/db", "A=1"], "Labels": {}},
            "State": {"Status": "running"}, "HostConfig": {}, "Mounts": [], "NetworkSettings": {"Networks": {}},
        }]
        sys_stdin = sys.stdin
        sys.stdin = io.StringIO(json.dumps(inspect))
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                h.main(["sanitize-inspect"])
        finally:
            sys.stdin = sys_stdin
        out = buf.getvalue()
        self.assertIn("DATABASE_URL", out)
        self.assertNotIn("postgresql://", out)
        self.assertEqual(h.scan_text(out), [])


if __name__ == "__main__":
    unittest.main()
