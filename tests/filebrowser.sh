#!/usr/bin/env bash
# File browser toggle, compose profile, and shared config source.
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
  rm -rf "$tmp" "$ROOT/deploy/filebrowser-data"
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
PUID=1000
PGID=1000
TZ=Asia/Tokyo
HTTP_PORT=
FILEBROWSER=off
FILEBROWSER_NOAUTH=false
EOF
chmod 600 "$ENV_FILE"

stub="$tmp/bin"
mkdir -p "$stub"
cat > "$stub/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_LOG:?}"
if [[ "$*" == *"compose"* && "$*" == *"config"* ]]; then
  exit 0
fi
exit 0
EOF
chmod 755 "$stub/docker"

export STUB_LOG="$tmp/on.log"
: > "$STUB_LOG"
PATH="$stub:$PATH" bash "$ROOT/webtop.sh" filebrowser on >/dev/null
grep -q '^FILEBROWSER=on$' "$ENV_FILE"
grep -q -- '--profile filebrowser' "$STUB_LOG"
grep -q 'up -d --no-deps --build nginx' "$STUB_LOG"
grep -q 'up -d --no-deps --force-recreate filebrowser' "$STUB_LOG"
grep -q 'baseURL: "/fi"' "$ROOT/deploy/filebrowser/config.yaml"
grep -q 'location /fi/' "$ROOT/deploy/nginx/nginx.conf"
if grep -q 'location /files/' "$ROOT/deploy/nginx/nginx.conf"; then
  echo "nginx still proxies /files/ to filebrowser" >&2
  exit 1
fi
test -d "$ROOT/deploy/filebrowser-data/tmp"

export STUB_LOG="$tmp/off.log"
: > "$STUB_LOG"
PATH="$stub:$PATH" bash "$ROOT/webtop.sh" filebrowser off >/dev/null
grep -q '^FILEBROWSER=off$' "$ENV_FILE"
grep -q -- '--profile filebrowser' "$STUB_LOG"
grep -q 'rm -sf filebrowser' "$STUB_LOG"

status=$(PATH="$stub:$PATH" bash "$ROOT/webtop.sh" filebrowser status)
printf '%s\n' "$status" | grep -q '설정: 꺼짐'
printf '%s\n' "$status" | grep -q 'FILEBROWSER_NOAUTH)=false'

if bash "$ROOT/webtop.sh" filebrowser nope >/dev/null 2>&1; then
  echo "bad filebrowser action was accepted" >&2
  exit 1
fi

# Shared source: override bind is exported for both services.
cat > "$OVERRIDE" <<'EOF'
services:
  webtop:
    volumes:
      - /docker/shark.ikenew.top/data:/config
EOF
export STUB_LOG="$tmp/src.log"
: > "$STUB_LOG"
# The stub cannot show the exported env. Source the helper by running a
# tiny bash snippet that uses the same function through `filebrowser status`.
src=$(PATH="$stub:$PATH" bash "$ROOT/webtop.sh" filebrowser status)
printf '%s\n' "$src" | grep -q '데이터 원본: /docker/shark.ikenew.top/data'

echo "filebrowser toggle ok"
