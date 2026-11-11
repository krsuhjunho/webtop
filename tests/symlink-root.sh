#!/usr/bin/env bash
# A symlink invoked from another directory must use the repo, not the link path.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'cleanup' EXIT
ENV_FILE="$ROOT/deploy/.env"
backup=""

cleanup() {
  if [[ -n "$backup" ]]; then
    cp "$backup" "$ENV_FILE"
  else
    rm -f "$ENV_FILE"
  fi
  rm -rf "$tmp"
}

if [[ -f "$ENV_FILE" ]]; then
  backup=$(mktemp)
  cp "$ENV_FILE" "$backup"
fi
rm -f "$ENV_FILE"

mkdir -p "$tmp/bin/deploy" "$tmp/elsewhere"
cat > "$tmp/bin/deploy/.env" <<'EOF'
MAXMIND_ACCOUNT_ID=decoy
MAXMIND_LICENSE_KEY=decoy
CERTADMIN_PROXY_SECRET=0123456789abcdef0123456789abcdef
PUID=1000
PGID=1000
EOF
ln -s "$ROOT/webtop.sh" "$tmp/bin/webtop"
ln -s "$tmp/bin/webtop" "$tmp/elsewhere/webtop"

out=$(cd "$tmp/elsewhere" && "$tmp/bin/webtop" precheck 2>&1 || true)
printf '%s\n' "$out" | grep -q 'deploy/.env: 없음'
if printf '%s\n' "$out" | grep -q 'MaxMind 설정됨'; then
  echo "symlink followed the link directory instead of the repo" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

path_out=$(cd / && PATH="$tmp/bin:$PATH" command webtop precheck 2>&1 || true)
printf '%s\n' "$path_out" | grep -q 'deploy/.env: 없음'

if [[ "$(id -u)" -ne 0 ]]; then
  link_out=$("$ROOT/webtop.sh" link 2>&1 || true)
  printf '%s\n' "$link_out" | grep -q 'root'
  if [[ -e /usr/local/bin/webtop && ! -L /usr/local/bin/webtop ]]; then
    echo "link created a non-symlink without root" >&2
    exit 1
  fi
fi

cat > "$ENV_FILE" <<'EOF'
MAXMIND_ACCOUNT_ID=1
MAXMIND_LICENSE_KEY=dummy
CERTADMIN_PROXY_SECRET=0123456789abcdef0123456789abcdef
PUID=1000
PGID=1000
TZ=Asia/Tokyo
HTTP_PORT=
UPDATE_MODE=check
EOF
chmod 600 "$ENV_FILE"
cat > "$tmp/crontab" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-l" ]]; then
  exit 1
fi
cp "$1" "${CRON_OUT:?}"
EOF
chmod 755 "$tmp/crontab"
export CRON_OUT="$tmp/installed.cron"
cd "$tmp/elsewhere"
CRONTAB="$tmp/crontab" "$tmp/elsewhere/webtop" cron-install --schedule '0 6 * * 1' --mode check >/dev/null
grep -q "$ROOT/webtop.sh auto-update" "$CRON_OUT"
if grep -q "$tmp/bin/webtop auto-update" "$CRON_OUT"; then
  echo "cron used the symlink path" >&2
  cat "$CRON_OUT" >&2
  exit 1
fi
echo "symlink root ok"
