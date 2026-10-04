#!/usr/bin/env bash
# Simulated-VPS integration test for the Trinity installer.
#
# DESTRUCTIVE TO THE TEST HOST: creates /opt/blackwell, /etc/blackwell, the
# `blackwell` user, Docker containers/volumes/networks, and removes them on the
# next run. It refuses to run on a host that has a real installation.
#
#   TRINITY_TEST_DESTRUCTIVE=1 TRINITY_TEST_SOURCE=/path/to/the-black-well tests/integration.sh
#
# Each PASS line is printed only after its assertion has executed.
set -Eeuo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
T="$here/bin/trinity"
SRC="${TRINITY_TEST_SOURCE:-https://github.com/tidewaterrepair-code/the-black-well.git}"
REF="${TRINITY_TEST_REF:-445267c03cba59e4538b80663b0a7ed1926a0956}"
GOLDEN="${TRINITY_TEST_GOLDEN:-edd4f0f16d45261c893cc5c0e1ff33fea28f2a01}"
STATE=/home/blackwell/trinity-maintenance/installer
MARK=/opt/blackwell/.trinity-integration-test
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

[[ "${TRINITY_TEST_DESTRUCTIVE:-0}" == 1 ]] || fail "set TRINITY_TEST_DESTRUCTIVE=1 (this test wipes /opt/blackwell on the test host)"
[[ "$(id -u)" == 0 ]] || fail "run as root"
if [[ -e /opt/blackwell && ! -e "$MARK" ]]; then
  fail "/opt/blackwell exists and is not an integration-test install; refusing"
fi

reset_host() {
  docker ps -aq --filter name=blackwell | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker ps -aq --filter name=trinity- | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker ps -aq --filter name=sim- | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm blackwell_postgres_data >/dev/null 2>&1 || true
  docker network rm blackwell_backend blackwell_edge blackwell_model_bus blackwell_codex_egress >/dev/null 2>&1 || true
  rm -rf /opt/blackwell /etc/blackwell /root/trinity-initial-credentials.txt "$STATE"
}
reset_host

# 1. Fresh install, database proof only ------------------------------------
"$T" --yes install --repo "$SRC" --ref "$REF" --no-start >"$work/install.log" 2>&1 || { cat "$work/install.log"; fail "fresh install"; }
touch "$MARK"
grep -q 'fresh migration chain: 51 files, ledger 38 rows, latest 0051' "$work/install.log" || fail "migration chain proof"
pass "fresh install: 51 migration files, 38 ledger rows, latest 0051"
"$T" --yes install --repo "$SRC" --no-start >"$work/reinstall.log" 2>&1 && fail "install ran over an existing installation"
grep -q 'install never runs over it' "$work/reinstall.log" || fail "refusal message"
pass "install refuses to run over an existing installation"
grep -q "Sovereign operator 'sovereign' created" "$work/install.log" || fail "sovereign operator"
pass "Sovereign operator bootstrapped; credentials only in root-only file"

# 2. Simulated existing VPS: served UI + stand-in Edge ------------------------------
(cd /opt/blackwell && docker compose -p blackwell up -d --no-deps --build web >/dev/null 2>&1) || true
for a in api operator-auth operator-admission-broker; do
  docker run -d --name "sim-$a" --network blackwell_edge --network-alias "$a" nginx:1.27-alpine >/dev/null
done
docker run -d --name blackwell-edge --network blackwell_edge nginx:1.27-alpine >/dev/null
docker restart blackwell-web >/dev/null
sleep 5
docker exec blackwell-web wget -qO- http://127.0.0.1:8080/ | grep -qi '<!DOCTYPE html>' || fail "web not serving"
edge_before="$(docker inspect -f '{{.Id}} {{.State.StartedAt}}' blackwell-edge)"
echo "// uncommitted refinement" >>/opt/blackwell/apps/web/app.js

# 3. Protect -------------------------------------------------------------------------
"$T" protect >"$work/protect.log" 2>&1 || { tail -30 "$work/protect.log"; fail "protect"; }
grep -q 'restore proof    : PASS' "$work/protect.log" || fail "restore proof"
pass "protect: discovery + UI snapshot + provisioning export + backup with restore proof PASS"
grep -q 'changed: app.js' "$STATE"/*-discover/summary.txt || fail "served-vs-source drift not reported"
pass "discovery reports the uncommitted UI change that is not being served"
snap="$(readlink -f "$STATE/ui-snapshots/latest")"
(cd "$snap" && sha256sum --quiet -c SHA256SUMS) || fail "snapshot checksums"
pass "UI snapshot checksums verify"

# 4. UI drift and restore ---------------------------------------------------------------
(cd /opt/blackwell && docker compose -p blackwell up -d --no-deps --build web >/dev/null 2>&1)
sleep 4
"$T" ui verify >/dev/null 2>&1 && fail "drift not detected"
pass "ui verify detects a rebuilt, changed UI"
"$T" ui restore --snapshot "$snap" --yes >"$work/restore.log" 2>&1 || { cat "$work/restore.log"; fail "ui restore"; }
"$T" ui verify >/dev/null 2>&1 || fail "ui verify after restore"
pass "ui restore returns the exact preserved UI bytes"
pre="$(find "$STATE/ui-snapshots" -maxdepth 1 -name '*-pre-restore' | head -1)"
docker rmi "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pinned_tag"])' "$pre/provenance.json")" >/dev/null
"$T" ui restore --snapshot "$pre" --yes >/dev/null 2>&1 || fail "restore from image tar"
"$T" ui restore --snapshot "$snap" --yes >/dev/null 2>&1 || fail "restore back"
"$T" ui verify >/dev/null 2>&1 || fail "verify after round trip"
pass "restore reloads a deleted preserved image from its saved tar"
[[ "$(docker inspect -f '{{.Id}} {{.State.StartedAt}}' blackwell-edge)" == "$edge_before" ]] || fail "Edge changed"
pass "Edge identity unchanged across protect/restore"

# 5. Maintenance access ---------------------------------------------------------------------
if command -v sshd >/dev/null && command -v ssh >/dev/null; then
  mkdir -p /run/sshd; ssh-keygen -A >/dev/null
  pgrep -f 'sshd -p 2222' >/dev/null || /usr/sbin/sshd -p 2222 -o PasswordAuthentication=no
  ssh-keygen -q -t ed25519 -N '' -f "$work/k"
  sid="$("$T" access grant --pubkey "$work/k.pub" --ttl 1h 2>/dev/null)"
  o=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR -p 2222 -i "$work/k")
  [[ "$(ssh "${o[@]}" blackwell@127.0.0.1 id -un)" == blackwell ]] || fail "granted key login"
  pass "granted key logs in as non-root blackwell"
  past="$(date -d '-2 minutes' +%Y%m%d%H%M%S)"
  sed -i "/$sid/s/expiry-time=\"[0-9]*\"/expiry-time=\"$past\"/" /home/blackwell/.ssh/authorized_keys
  ssh "${o[@]}" blackwell@127.0.0.1 true 2>/dev/null && fail "expired key accepted"
  pass "sshd refuses the key once expiry-time has passed"
  "$T" access revoke --session "$sid" >/dev/null 2>&1
  grep -q "$sid" /home/blackwell/.ssh/authorized_keys && fail "key still present"
  grep -q '"status": "CLOSED"' "$STATE/access/$sid.json" || fail "closure record"
  pass "revocation removes the key and writes a closure record"
else
  echo "SKIP access tests (sshd/ssh not installed)"
fi

# 6. Stage: upgrade proof from a golden-baseline database ----------------------------------------
mkdir -p "$work/old/src" "$work/bk/db"
git -C /opt/blackwell -c safe.directory='*' archive "$GOLDEN" | tar -C "$work/old/src" -xf -
docker run -d --name trinity-old-prod --network none -e POSTGRES_USER=blackwell -e POSTGRES_DB=blackwell -e POSTGRES_PASSWORD=x \
  pgvector/pgvector:0.8.5-pg17-bookworm >/dev/null
for _ in $(seq 1 40); do docker exec trinity-old-prod sh -c 'PGPASSWORD=x psql -h 127.0.0.1 -U blackwell -d blackwell -Atqc "select 1"' >/dev/null 2>&1 && break; sleep 1; done
docker exec trinity-old-prod psql -U blackwell -d blackwell -qc "CREATE EXTENSION IF NOT EXISTS vector; CREATE ROLE blackwell_admin NOLOGIN; CREATE ROLE blackwell_runtime NOLOGIN INHERIT;"
for m in "$work"/old/src/database/migrations/*.sql; do docker exec -i trinity-old-prod psql -X -q -v ON_ERROR_STOP=1 -U blackwell -d blackwell <"$m" >/dev/null 2>&1; done
docker exec trinity-old-prod pg_dump -U blackwell -d blackwell -Fc >"$work/bk/db/database.dump"
docker exec trinity-old-prod pg_dumpall -U blackwell --roles-only --no-role-passwords >"$work/bk/db/roles.sql"
docker exec trinity-old-prod psql -X -At -U blackwell -d blackwell -c "select version from blackwell.schema_migrations order by version" >"$work/bk/db/ledger.txt"
docker rm -f trinity-old-prod >/dev/null
(cd "$work/bk" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
"$T" stage --ref "$REF" --backup "$work/bk" >"$work/stage.log" 2>&1 || { tail -20 "$work/stage.log"; fail "stage"; }
rep="$(ls -d "$STATE"/stage/* | tail -1)/REPORT.md"
grep -q 'upgrade proof: PASS from ledger 0048, applied 3 file(s)' "$rep" || fail "upgrade proof"
grep -q 'provisioning fresh vs upgrade: IDENTICAL' "$rep" || fail "provisioning equality"
pass "stage: golden 0048 database upgrades to 0051 in scratch; fresh and upgrade privilege profiles identical"

# 7. No secret material in any report ----------------------------------------------------------
find "$STATE" \( -name '*.json' -o -name '*.txt' -o -name '*.md' -o -name '*.sql' \) \
  ! -path '*/source/*' ! -name 'roles.sql' ! -path '*/served/*' -print0 \
  | xargs -0 python3 "$here/lib/trinity_helper.py" scan-secrets || fail "secret material found in reports"
pass "secret scan clean across all reports"

echo "ALL INTEGRATION CHECKS PASSED"
