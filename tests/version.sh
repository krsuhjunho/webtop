#!/usr/bin/env bash
# version is local only unless --check, and status/motd reuse the same line.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/plain" "$tmp/repo/deploy"
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "${1:-}" == "compose" ]]; then
  printf 'NAME STATUS\nwebtop running\n'
  exit 0
fi
if [[ "${DOCKER_MODE:-running}" == "absent" ]]; then
  exit 1
fi
for arg in "$@"; do
  case "$arg" in
    *Running*) printf 'true\n'; exit 0 ;;
    *RepoDigests*) printf 'ghcr.io/krsuhjunho/webtop@sha256:ab12cd34deadbeef0123456789abcdef0123456789abcdef0123456789abcdef\n'; exit 0 ;;
    *revision*) printf 'c2351eb0123456789abcdef0123456789abcdef\n'; exit 0 ;;
    *created*) printf '2026-11-11T03:17:00+00:00\n'; exit 0 ;;
    *'.Image'*) printf 'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n'; exit 0 ;;
  esac
done
exit 0
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
exit 1
EOF
chmod 755 "$tmp/bin/docker" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
export DOCKER_LOG="$tmp/docker.log"
export CURL_LOG="$tmp/curl.log"
export DOCKER_MODE=absent
export WEBTOP_LOGIN_CACHE="$tmp/login.cache"
: >"$DOCKER_LOG"
: >"$CURL_LOG"

cp "$ROOT/webtop.sh" "$tmp/plain/webtop.sh"
chmod 755 "$tmp/plain/webtop.sh"
plain=$("$tmp/plain/webtop.sh" version)
printf '%s\n' "$plain" | head -n 1 | grep -q 'webtop unknown · selkies · not running · 확인 안 됨' \
  || { printf '%s\n' "$plain" >&2; fail "plain checkout line"; }
[[ -s "$CURL_LOG" ]] && fail "version called the network"
[[ "$(wc -l <<<"$plain")" -eq 1 ]] || fail "plain version printed details"

cp "$ROOT/webtop.sh" "$tmp/repo/webtop.sh"
chmod 755 "$tmp/repo/webtop.sh"
git -C "$tmp/repo" init -q -b main
git -C "$tmp/repo" config user.email test@example.com
git -C "$tmp/repo" config user.name test
printf 'readme\n' >"$tmp/repo/README.md"
git -C "$tmp/repo" add webtop.sh README.md
GIT_AUTHOR_DATE='2026-11-11T01:02:03Z' GIT_COMMITTER_DATE='2026-11-11T01:02:03Z' \
  git -C "$tmp/repo" commit -q -m 'base'
sha=$(git -C "$tmp/repo" rev-parse --short=7 HEAD)
cat >"$tmp/repo/deploy/.env" <<'EOF'
WEBTOP_VARIANT=kasm
IMAGE_TAG=kasm
PUID=1000
PGID=1000
CERTADMIN_PROXY_SECRET=0123456789abcdef0123456789abcdef
LOGIN_CHECK=prompt
LOGIN_SHOW_VERSION=on
EOF
cat >"$WEBTOP_LOGIN_CACHE" <<EOF
checked_at=$(date +%s)
repo=current
repo_tip=${sha}
image=current
image_id=sha256:ab12cd34
tag=kasm
fingerprint=${sha}:sha256:ab12cd34
skip_key=
skip_until=0
EOF

export DOCKER_MODE=running
: >"$DOCKER_LOG"
: >"$CURL_LOG"
ver=$("$tmp/repo/webtop.sh" --version)
printf '%s\n' "$ver" | head -n 1 | grep -q "webtop ${sha} (2026-11-11) · kasm · image sha256:ab12cd34 · 최신" \
  || { printf '%s\n' "$ver" >&2; fail "running version line"; }
printf '%s\n' "$ver" | grep -q 'image revision c2351eb · created 2026-11-11T03:17:00+00:00' \
  || fail "missing image labels"
[[ -s "$CURL_LOG" ]] && fail "--version called the network"

: >"$CURL_LOG"
"$tmp/repo/webtop.sh" version --check >/dev/null || true
[[ -s "$CURL_LOG" ]] || fail "--check did not refresh"

printf '%s\n' "$plain" >/dev/null
cat >"$WEBTOP_LOGIN_CACHE" <<EOF
checked_at=$(date +%s)
repo=behind
repo_tip=abc
image=current
image_id=sha256:ab12cd34
tag=kasm
fingerprint=abc:sha256:ab12cd34
skip_key=
skip_until=0
EOF
behind=$("$tmp/repo/webtop.sh" -v)
printf '%s\n' "$behind" | head -n 1 | grep -q ' · 업데이트 있음$' || fail "behind cache word"

rm -f "$WEBTOP_LOGIN_CACHE"
missing=$("$tmp/repo/webtop.sh" version)
printf '%s\n' "$missing" | head -n 1 | grep -q ' · 확인 안 됨$' || fail "missing cache word"

export DOCKER_MODE=absent
status=$("$tmp/repo/webtop.sh" status)
printf '%s\n' "$status" | head -n 1 | grep -q "webtop ${sha} (2026-11-11) · kasm · not running · 확인 안 됨" \
  || { printf '%s\n' "$status" >&2; fail "status did not start with the version line"; }
printf '%s\n' "$status" | grep -q 'webtop running' || fail "status skipped compose"

export DOCKER_MODE=running
cat >"$WEBTOP_LOGIN_CACHE" <<EOF
checked_at=$(date +%s)
repo=current
repo_tip=${sha}
image=current
image_id=sha256:ab12cd34
tag=kasm
fingerprint=${sha}:sha256:ab12cd34
skip_key=
skip_until=0
EOF
shown=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 "$tmp/repo/webtop.sh" motd </dev/null 2>&1 || true)
printf '%s\n' "$shown" | head -n 1 | grep -q "webtop ${sha} (2026-11-11) · kasm · image sha256:ab12cd34 · 최신" \
  || { printf '%s\n' "$shown" >&2; fail "login did not show the version"; }
if printf '%s\n' "$shown" | grep -qF '업데이트를 지금 진행할까요?'; then
  fail "current login prompted"
fi

sed -i 's/^LOGIN_SHOW_VERSION=on/LOGIN_SHOW_VERSION=off/' "$tmp/repo/deploy/.env"
hidden=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 "$tmp/repo/webtop.sh" motd </dev/null 2>&1 || true)
[[ -z "$hidden" ]] || fail "LOGIN_SHOW_VERSION=off printed: $hidden"

cat >"$WEBTOP_LOGIN_CACHE" <<EOF
checked_at=$(date +%s)
repo=behind
repo_tip=abc
image=current
image_id=sha256:ab12cd34
tag=kasm
fingerprint=abc:sha256:ab12cd34
skip_key=
skip_until=0
EOF
notice=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 "$tmp/repo/webtop.sh" motd <<<'n' 2>&1 || true)
first=$(printf '%s\n' "$notice" | head -n 1)
printf '%s\n' "$first" | grep -q ' · 업데이트 있음$' || { printf '%s\n' "$notice" >&2; fail "notice did not start with version"; }
printf '%s\n' "$notice" | grep -q '저장소 업데이트가 있습니다' || fail "notice missed the update text"

quiet=$( "$tmp/repo/webtop.sh" motd </dev/null 2>&1 || true)
[[ -z "$quiet" ]] || fail "non-interactive motd printed: $quiet"

printf 'ok\n'
