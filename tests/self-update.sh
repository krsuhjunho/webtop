#!/usr/bin/env bash
# self-update fast-forwards a checkout and leaves untracked deploy files alone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file=$1 text=$2
  if ! grep -qF "$text" "$file"; then
    printf 'missing %s in %s\n' "$text" "$file" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file=$1 text=$2
  if grep -qF "$text" "$file"; then
    printf 'unexpected %s in %s\n' "$text" "$file" >&2
    cat "$file" >&2
    exit 1
  fi
}

git_ident() {
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}

seed_private() {
  local dest=$1 mode=${2:-check} self=${3:-on}
  mkdir -p "$dest/deploy/certs" "$dest/deploy/filebrowser-data"
  cat >"$dest/deploy/.env" <<EOF
MAXMIND_ACCOUNT_ID=1
MAXMIND_LICENSE_KEY=dummy
CERTADMIN_PROXY_SECRET=0123456789abcdef0123456789abcdef
PUID=1000
PGID=1000
TZ=Asia/Tokyo
HTTP_PORT=
UPDATE_MODE=${mode}
SELF_UPDATE=${self}
WEBTOP_VARIANT=selkies
IMAGE_TAG=latest
FILEBROWSER=off
TOKEN=keep-me
EOF
  chmod 600 "$dest/deploy/.env"
  printf 'UNTRACKED_OVERRIDE\n' >"$dest/deploy/compose.override.yml"
  printf 'CERTDATA\n' >"$dest/deploy/certs/client.p12"
  printf 'FBDATA\n' >"$dest/deploy/filebrowser-data/keep.txt"
}

assert_private() {
  local dest=$1
  assert_contains "$dest/deploy/.env" "TOKEN=keep-me"
  assert_contains "$dest/deploy/compose.override.yml" "UNTRACKED_OVERRIDE"
  assert_contains "$dest/deploy/certs/client.p12" "CERTDATA"
  assert_contains "$dest/deploy/filebrowser-data/keep.txt" "FBDATA"
}

clone_at() {
  local name=$1 rev=$2 dest
  dest="$tmp/work-$name"
  rm -rf "$dest"
  git clone --quiet "$tmp/origin.git" "$dest"
  git_ident "$dest"
  git -C "$dest" checkout -q -B main "$rev"
  seed_private "$dest"
  printf '%s\n' "$dest"
}

run_script() {
  local dest=$1
  shift
  (
    cd "$dest"
    PATH="$tmp/bin:$PATH" \
      DOCKER_LOG="$tmp/docker.log" \
      CURL_LOG="$tmp/curl.log" \
      ./webtop.sh "$@"
  )
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "${1:-}" == "ps" ]]; then
  printf '%s\n' webtop-nginx
  printf '%s\n' webtop-certadmin
fi
exit 0
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
exit 1
EOF
cat >"$tmp/bin/crontab" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-l" ]]; then
  exit 1
fi
cp "$1" "${CRON_OUT:?}"
EOF
chmod 755 "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/crontab"
: >"$tmp/docker.log"
: >"$tmp/curl.log"
export GIT_TERMINAL_PROMPT=0

git init --bare -q "$tmp/origin.git"
git init -q -b main "$tmp/src"
git_ident "$tmp/src"
mkdir -p "$tmp/src/deploy/nginx" "$tmp/src/deploy/certadmin"
cp "$ROOT/webtop.sh" "$tmp/src/webtop.sh"
chmod 755 "$tmp/src/webtop.sh"
printf 'services: {}\n' >"$tmp/src/deploy/docker-compose.yml"
printf 'nginx-a\n' >"$tmp/src/deploy/nginx/nginx.conf"
printf 'FROM scratch\n' >"$tmp/src/deploy/certadmin/Dockerfile"
git -C "$tmp/src" add webtop.sh deploy
git -C "$tmp/src" commit -q -m 'base'
git -C "$tmp/src" remote add origin "$tmp/origin.git"
git -C "$tmp/src" push -q -u origin main
git --git-dir "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
shaA=$(git -C "$tmp/src" rev-parse HEAD)

printf 'nginx-b\n' >>"$tmp/src/deploy/nginx/nginx.conf"
sed -i 's/다시 만듭니다:/다시 만듭니다 REEXEC:/' "$tmp/src/webtop.sh"
grep -q '다시 만듭니다 REEXEC:' "$tmp/src/webtop.sh"
git -C "$tmp/src" add webtop.sh deploy/nginx/nginx.conf
git -C "$tmp/src" commit -q -m 'build nginx'
shaB=$(git -C "$tmp/src" rev-parse HEAD)

printf 'certadmin-c\n' >>"$tmp/src/deploy/certadmin/Dockerfile"
git -C "$tmp/src" add deploy/certadmin/Dockerfile
git -C "$tmp/src" commit -q -m 'build certadmin'
shaC=$(git -C "$tmp/src" rev-parse HEAD)

printf 'readme-only\n' >"$tmp/src/README.md"
git -C "$tmp/src" add README.md
git -C "$tmp/src" commit -q -m 'docs only'
shaD=$(git -C "$tmp/src" rev-parse HEAD)
git -C "$tmp/src" push -q origin main

# Dirty tracked files are kept and block a fast-forward.
work=$(clone_at dirty "$shaA")
printf 'LOCALDIRTY\n' >>"$work/deploy/docker-compose.yml"
set +e
dirty_out=$(run_script "$work" self-update --yes 2>&1)
dirty_rc=$?
set -e
[[ "$dirty_rc" -ne 0 ]] || fail "dirty tree was updated"
[[ "$(git -C "$work" rev-parse HEAD)" == "$shaA" ]] || fail "dirty tree moved HEAD"
assert_contains "$work/deploy/docker-compose.yml" "LOCALDIRTY"
assert_private "$work"
printf '%s\n' "$dirty_out" | grep -q 'docker-compose.yml'
printf '%s\n' "$dirty_out" | grep -q '버리지 않습니다'

# --check reports commits and does not move HEAD.
set +e
check_out=$(run_script "$work" self-update --check 2>&1)
check_rc=$?
set -e
[[ "$check_rc" -eq 10 ]] || fail "check mode exit $check_rc"
[[ "$(git -C "$work" rev-parse HEAD)" == "$shaA" ]] || fail "check mode moved HEAD"
assert_contains "$work/deploy/docker-compose.yml" "LOCALDIRTY"
printf '%s\n' "$check_out" | grep -q 'build nginx'
printf '%s\n' "$check_out" | grep -q 'check 모드'
assert_contains "$work/deploy/logs/update.log" "build nginx"

# --stash keeps the tracked edit out of the way and fast-forwards.
: >"$tmp/docker.log"
set +e
stash_out=$(run_script "$work" self-update --stash --yes 2>&1)
stash_rc=$?
set -e
[[ "$stash_rc" -eq 0 ]] || { printf '%s\n' "$stash_out" >&2; fail "stash update exit $stash_rc"; }
[[ "$(git -C "$work" rev-parse HEAD)" == "$shaD" ]] || fail "stash update did not fast-forward"
assert_not_contains "$work/deploy/docker-compose.yml" "LOCALDIRTY"
git -C "$work" stash show -p | grep -q 'LOCALDIRTY'
assert_private "$work"
if git -C "$work" stash show -p | grep -q 'keep-me'; then
  fail "stash included the untracked env file"
fi
printf '%s\n' "$stash_out" | grep -q '새 webtop.sh'
printf '%s\n' "$stash_out" | grep -q '다시 만듭니다 REEXEC:'
assert_contains "$tmp/docker.log" "up -d --build --no-deps nginx certadmin"
[[ -z "$(git -C "$work" status --porcelain --untracked-files=no)" ]] || fail "tracked tree dirty after stash update"

# upgrade is the same command. A current checkout is left alone.
current=$(clone_at current "$shaD")
run_script "$current" upgrade --check >/dev/null
[[ "$(git -C "$current" rev-parse HEAD)" == "$shaD" ]] || fail "upgrade --check moved HEAD"

# Local commits are not reset.
printf 'local-only\n' >>"$current/README.md"
git -C "$current" add README.md
git -C "$current" commit -q -m 'local only'
local_sha=$(git -C "$current" rev-parse HEAD)
set +e
ahead_out=$(run_script "$current" self-update --yes 2>&1)
ahead_rc=$?
set -e
[[ "$ahead_rc" -ne 0 ]] || fail "ahead checkout was reset"
[[ "$(git -C "$current" rev-parse HEAD)" == "$local_sha" ]] || fail "ahead HEAD changed"
assert_contains "$current/README.md" "local-only"
printf '%s\n' "$ahead_out" | grep -q '덮어쓰지 않습니다'

# Diverged history is refused.
diverged=$(clone_at diverged "$shaA")
printf 'side-commit\n' >>"$diverged/README.md"
git -C "$diverged" add README.md
git -C "$diverged" commit -q -m 'side'
side_sha=$(git -C "$diverged" rev-parse HEAD)
set +e
div_out=$(run_script "$diverged" upgrade --yes 2>&1)
div_rc=$?
set -e
[[ "$div_rc" -ne 0 ]] || fail "diverged checkout was merged"
[[ "$(git -C "$diverged" rev-parse HEAD)" == "$side_sha" ]] || fail "diverged HEAD changed"
assert_contains "$diverged/README.md" "side-commit"
printf '%s\n' "$div_out" | grep -q '갈라져'
assert_private "$diverged"

# certadmin context rebuilds only that service. The script itself is unchanged.
cert=$(clone_at cert "$shaB")
: >"$tmp/docker.log"
run_script "$cert" self-update --yes >/dev/null
[[ "$(git -C "$cert" rev-parse HEAD)" == "$shaD" ]] || fail "cert update did not fast-forward"
assert_contains "$tmp/docker.log" "up -d --build --no-deps certadmin"
if grep -q 'no-deps nginx' "$tmp/docker.log"; then
  fail "nginx was rebuilt for a certadmin-only change"
fi
assert_private "$cert"

# A docs-only pull does not recreate services.
docs=$(clone_at docs "$shaC")
: >"$tmp/docker.log"
run_script "$docs" self-update --yes >/dev/null
[[ "$(git -C "$docs" rev-parse HEAD)" == "$shaD" ]] || fail "docs update did not fast-forward"
if grep -q 'up -d' "$tmp/docker.log"; then
  fail "services were recreated for a docs-only change"
fi
assert_contains "$docs/README.md" "readme-only"

# Weekly check reports the repo and does not apply it.
auto_check=$(clone_at auto-check "$shaA")
set +e
auto_check_out=$(run_script "$auto_check" auto-update 2>&1)
auto_check_rc=$?
set -e
[[ "$auto_check_rc" -eq 0 ]] || { printf '%s\n' "$auto_check_out" >&2; fail "auto check exit $auto_check_rc"; }
[[ "$(git -C "$auto_check" rev-parse HEAD)" == "$shaA" ]] || fail "auto check moved HEAD"
printf '%s\n' "$auto_check_out" | grep -q 'check 모드'
printf '%s\n' "$auto_check_out" | grep -q 'build nginx'
[[ -s "$tmp/curl.log" ]] || fail "auto check skipped the image lookup"

# Apply updates the checkout first, then attempts the image update.
auto_apply=$(clone_at auto-apply "$shaC")
sed -i 's/^UPDATE_MODE=check/UPDATE_MODE=apply/' "$auto_apply/deploy/.env"
: >"$tmp/curl.log"
: >"$tmp/docker.log"
set +e
run_script "$auto_apply" auto-update >/dev/null 2>&1
apply_rc=$?
set -e
[[ "$apply_rc" -ne 0 ]] || fail "image lookup unexpectedly succeeded"
[[ "$(git -C "$auto_apply" rev-parse HEAD)" == "$shaD" ]] || fail "auto apply did not fast-forward"
[[ -s "$tmp/curl.log" ]] || fail "auto apply skipped the image update"
if grep -q 'up -d' "$tmp/docker.log"; then
  fail "auto apply recreated services for a docs-only change"
fi
assert_private "$auto_apply"

# SELF_UPDATE=off leaves the checkout where it is.
auto_off=$(clone_at auto-off "$shaA")
sed -i 's/^SELF_UPDATE=on/SELF_UPDATE=off/' "$auto_off/deploy/.env"
sed -i 's/^UPDATE_MODE=check/UPDATE_MODE=apply/' "$auto_off/deploy/.env"
set +e
off_out=$(run_script "$auto_off" auto-update 2>&1)
set -e
[[ "$(git -C "$auto_off" rev-parse HEAD)" == "$shaA" ]] || fail "SELF_UPDATE=off moved HEAD"
printf '%s\n' "$off_out" | grep -q 'SELF_UPDATE=off'
assert_contains "$auto_off/deploy/.env" "TOKEN=keep-me"

# check-update reports origin/main even when self-update is off.
report=$(clone_at report "$shaA")
sed -i 's/^SELF_UPDATE=on/SELF_UPDATE=off/' "$report/deploy/.env"
set +e
report_out=$(run_script "$report" check-update 2>&1)
set -e
[[ "$(git -C "$report" rev-parse HEAD)" == "$shaA" ]] || fail "check-update moved HEAD"
printf '%s\n' "$report_out" | grep -q 'build certadmin'
printf '%s\n' "$report_out" | grep -q '자동 적용은 하지 않습니다'
assert_contains "$report/deploy/logs/update.log" "origin/main"

# Default cron is Monday 14:00 local.
cron_work=$(clone_at cron "$shaD")
export CRON_OUT="$tmp/installed.cron"
CRONTAB="$tmp/bin/crontab" run_script "$cron_work" cron-install >/dev/null
assert_contains "$CRON_OUT" "0 14 * * 1"
assert_contains "$CRON_OUT" "$cron_work/webtop.sh auto-update"
assert_contains "$cron_work/deploy/.env" "TOKEN=keep-me"

printf 'ok\n'
