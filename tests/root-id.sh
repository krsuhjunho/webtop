#!/usr/bin/env bash
# PUID/PGID 0 is rejected, and compose.override.yml is passed to compose.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'cleanup' EXIT
ENV_FILE="$ROOT/deploy/.env"
OVERRIDE="$ROOT/deploy/compose.override.yml"
backup=""
override_backup=""

cleanup() {
  if [[ -n "$backup" ]]; then
    cp "$backup" "$ENV_FILE"
  else
    rm -f "$ENV_FILE"
  fi
  if [[ -n "$override_backup" ]]; then
    cp "$override_backup" "$OVERRIDE"
  else
    rm -f "$OVERRIDE"
  fi
  rm -rf "$tmp"
}

if [[ -f "$ENV_FILE" ]]; then
  backup=$(mktemp)
  cp "$ENV_FILE" "$backup"
fi
if [[ -f "$OVERRIDE" ]]; then
  override_backup=$(mktemp)
  cp "$OVERRIDE" "$override_backup"
fi

cat > "$ENV_FILE" <<'EOF'
MAXMIND_ACCOUNT_ID=1
MAXMIND_LICENSE_KEY=dummy
CERTADMIN_PROXY_SECRET=0123456789abcdef0123456789abcdef
PUID=0
PGID=0
TZ=Asia/Tokyo
HTTP_PORT=
EOF
chmod 600 "$ENV_FILE"

pre=$(bash "$ROOT/webtop.sh" precheck 2>&1 || true)
printf '%s\n' "$pre" | grep -q 'not supposed to be run as root'

stub="$tmp/bin"
mkdir -p "$stub"
cat > "$stub/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_LOG:?}"
exit 0
EOF
chmod 755 "$stub/docker"

export STUB_LOG="$tmp/start.log"
: > "$STUB_LOG"
set +e
PATH="$stub:$PATH" bash "$ROOT/webtop.sh" start >"$tmp/start.out" 2>&1
start_rc=$?
set -e
[[ "$start_rc" -ne 0 ]]
grep -q 'VLC' "$tmp/start.out"
if [[ -s "$STUB_LOG" ]]; then
  echo "start invoked docker while PUID was 0" >&2
  cat "$STUB_LOG" >&2
  exit 1
fi

owner="$tmp/config"
mkdir -p "$owner"
sudo chown 1001:1001 "$owner"
cat > "$OVERRIDE" <<EOF
services:
  webtop:
    volumes:
      - ${owner}:/config
EOF

bash "$ROOT/webtop.sh" env --account 1 --license dummy --countries KR,JP >/dev/null
grep -q '^PUID=1001$' "$ENV_FILE"
grep -q '^PGID=1001$' "$ENV_FILE"

# Explicit 0 is replaced rather than stored.
bash "$ROOT/webtop.sh" env --account 1 --license dummy --countries KR,JP --puid 0 --pgid 0 >/dev/null
grep -q '^PUID=1001$' "$ENV_FILE"
grep -q '^PGID=1001$' "$ENV_FILE"

# Drop the bind mount and confirm a root shell still lands on 1000, not 0.
rm -f "$OVERRIDE"
sudo chown 0:0 "$owner" || true
printf '%s\n' 'PUID=0' 'PGID=0' >> "$ENV_FILE"
# The last assignment wins in env_get. Rewrite the keys cleanly.
python3 - "$ENV_FILE" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
lines = []
seen = set()
for line in path.read_text().splitlines():
    key = line.split("=", 1)[0]
    if key in {"PUID", "PGID"}:
        continue
    lines.append(line)
lines += ["PUID=0", "PGID=0"]
path.write_text("\n".join(lines) + "\n")
PY
SUDO_UID=0 SUDO_GID=0 bash "$ROOT/webtop.sh" env --account 1 --license dummy --countries KR,JP >/dev/null
grep -q '^PUID=1000$' "$ENV_FILE"
grep -q '^PGID=1000$' "$ENV_FILE"

cat > "$OVERRIDE" <<EOF
services:
  webtop:
    volumes:
      - ${owner}:/config
EOF
export STUB_LOG="$tmp/status.log"
: > "$STUB_LOG"
PATH="$stub:$PATH" bash "$ROOT/webtop.sh" status >/dev/null
grep -q -- "-f ${ROOT}/deploy/docker-compose.yml" "$STUB_LOG"
grep -q -- "-f ${ROOT}/deploy/compose.override.yml" "$STUB_LOG"
python3 - "$STUB_LOG" "$ROOT" <<'PY'
import sys
from pathlib import Path
log = Path(sys.argv[1]).read_text()
root = sys.argv[2]
line = next(l for l in log.splitlines() if "compose" in l and "docker-compose.yml" in l)
base = line.find(f"{root}/deploy/docker-compose.yml")
over = line.find(f"{root}/deploy/compose.override.yml")
if base < 0 or over < 0 or over < base:
    raise SystemExit(f"override is not after the base file: {line}")
PY
echo "root id ok"
