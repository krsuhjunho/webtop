#!/usr/bin/env bash
# Login notice reads a cache, prompts only on an interactive tty, and can fast-forward.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

git_ident() {
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/bash
exit 1
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
if [[ "$*" == *"-D -"* ]]; then
  printf 'docker-content-digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\r\n'
  exit 0
fi
if [[ "$*" == *token* ]]; then
  printf '%s' '{"token":"t"}'
  exit 0
fi
cat <<'JSON'
{
  "manifests": [
    {
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "platform": { "architecture": "amd64" }
    },
    {
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "platform": { "architecture": "arm64" }
    }
  ],
  "config": {
    "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }
}
JSON
EOF
chmod 755 "$tmp/bin/docker" "$tmp/bin/curl"
export CURL_LOG="$tmp/curl.log"
: >"$CURL_LOG"
export GIT_TERMINAL_PROMPT=0
export PATH="$tmp/bin:$PATH"
export WEBTOP_LOGIN_CACHE="$tmp/login.cache"
export WEBTOP_LOGIN_BASHRC="$tmp/bashrc"
export WEBTOP_LOGIN_PROFILE="$tmp/profile.d/webtop-update.sh"

git init --bare -q "$tmp/origin.git"
git init -q -b main "$tmp/src"
git_ident "$tmp/src"
cp "$ROOT/webtop.sh" "$tmp/src/webtop.sh"
chmod 755 "$tmp/src/webtop.sh"
printf 'base\n' >"$tmp/src/README.md"
git -C "$tmp/src" add webtop.sh README.md
git -C "$tmp/src" commit -q -m 'base'
git -C "$tmp/src" remote add origin "$tmp/origin.git"
git -C "$tmp/src" push -q -u origin main
git --git-dir "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
shaA=$(git -C "$tmp/src" rev-parse HEAD)
printf 'newer\n' >>"$tmp/src/README.md"
git -C "$tmp/src" add README.md
git -C "$tmp/src" commit -q -m 'newer readme'
shaB=$(git -C "$tmp/src" rev-parse HEAD)
git -C "$tmp/src" push -q origin main

git clone --quiet "$tmp/origin.git" "$tmp/work"
git_ident "$tmp/work"
git -C "$tmp/work" checkout -q -B main "$shaA"
mkdir -p "$tmp/work/deploy"
cat >"$tmp/work/deploy/.env" <<'EOF'
LOGIN_CHECK=prompt
LOGIN_CHECK_INTERVAL=6
WEBTOP_VARIANT=selkies
IMAGE_TAG=latest
PUID=1000
PGID=1000
EOF

run() {
  (
    cd "$tmp/work"
    ./webtop.sh "$@"
  )
}

run login-check refresh
grep -q '^repo=behind$' "$WEBTOP_LOGIN_CACHE" || { cat "$WEBTOP_LOGIN_CACHE" >&2; fail "refresh did not mark the repo behind"; }
grep -q '^image=behind$' "$WEBTOP_LOGIN_CACHE" || { cat "$WEBTOP_LOGIN_CACHE" >&2; fail "refresh did not mark the image behind"; }
[[ -s "$CURL_LOG" ]] || fail "refresh did not call the registry"

# A non-interactive invocation stays silent.
silent=$(run motd </dev/null 2>&1 || true)
[[ -z "$silent" ]] || fail "non-interactive motd printed: $silent"

now=$(date +%s)
cat >"$WEBTOP_LOGIN_CACHE" <<EOF
checked_at=${now}
repo=behind
repo_tip=${shaB}
image=current
image_id=sha256:ccc
tag=latest
fingerprint=${shaB}:sha256:ccc
skip_key=
skip_until=0
EOF

prompt_out=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 run motd <<<'n' 2>&1 || true)
printf '%s\n' "$prompt_out" | grep -qF '업데이트를 지금 진행할까요? [Y/n]' || { printf 'PROMPT OUT:\n%s\n' "$prompt_out" >&2; fail "missing prompt"; }
printf '%s\n' "$prompt_out" | grep -q 'self-update --yes' || fail "missing suggested command"
grep -q "^skip_key=${shaB}:sha256:ccc$" "$WEBTOP_LOGIN_CACHE" || fail "decline was not remembered"

again=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 run motd <<<'n' 2>&1 || true)
if printf '%s\n' "$again" | grep -qF '업데이트를 지금 진행할까요?'; then
  fail "declined update prompted again"
fi
printf '%s\n' "$again" | grep -q '나중에 실행' || fail "skip still needs the later command"

# A newer fingerprint asks again.
sed -i 's/^fingerprint=.*/fingerprint=new/' "$WEBTOP_LOGIN_CACHE"
sed -i 's/^skip_key=.*/skip_key=old/' "$WEBTOP_LOGIN_CACHE"
newer=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 run motd <<<'n' 2>&1 || true)
printf '%s\n' "$newer" | grep -qF '업데이트를 지금 진행할까요?' || fail "newer version did not prompt"

# Timeout or EOF skips without hanging.
cat >"$WEBTOP_LOGIN_CACHE" <<EOF
checked_at=${now}
repo=behind
repo_tip=${shaB}
image=current
image_id=sha256:ccc
tag=latest
fingerprint=${shaB}:sha256:ccc
skip_key=
skip_until=0
EOF
eof_out=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 run motd </dev/null 2>&1 || true)
printf '%s\n' "$eof_out" | grep -q '나중에 실행' || fail "eof did not skip"
grep -q "^skip_key=${shaB}:sha256:ccc$" "$WEBTOP_LOGIN_CACHE" || fail "eof did not remember the skip"

# notify prints the notice and does not ask.
sed -i 's/^LOGIN_CHECK=prompt/LOGIN_CHECK=notify/' "$tmp/work/deploy/.env"
sed -i 's/^skip_key=.*/skip_key=/' "$WEBTOP_LOGIN_CACHE"
sed -i 's/^skip_until=.*/skip_until=0/' "$WEBTOP_LOGIN_CACHE"
note=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 run motd <<<'y' 2>&1 || true)
printf '%s\n' "$note" | grep -q '저장소 업데이트가 있습니다' || fail "notify missed the notice"
if printf '%s\n' "$note" | grep -qF '업데이트를 지금 진행할까요?'; then
  fail "notify mode prompted"
fi
[[ "$(git -C "$tmp/work" rev-parse HEAD)" == "$shaA" ]] || fail "notify mode changed HEAD"

sed -i 's/^LOGIN_CHECK=notify/LOGIN_CHECK=off/' "$tmp/work/deploy/.env"
off=$(WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 run motd <<<'y' 2>&1 || true)
[[ -z "$off" ]] || fail "LOGIN_CHECK=off printed: $off"
sed -i 's/^LOGIN_CHECK=off/LOGIN_CHECK=prompt/' "$tmp/work/deploy/.env"

# Enter means yes and fast-forwards the checkout. The image is already current.
cat >"$WEBTOP_LOGIN_CACHE" <<EOF
checked_at=${now}
repo=behind
repo_tip=${shaB}
image=current
image_id=sha256:ccc
tag=latest
fingerprint=${shaB}:sha256:ccc
skip_key=
skip_until=0
EOF
WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 run motd <<<'' >/dev/null 2>&1 || true
[[ "$(git -C "$tmp/work" rev-parse HEAD)" == "$shaB" ]] || fail "enter did not fast-forward"

# Stale cache refreshes in the background and does not block.
cat >"$WEBTOP_LOGIN_CACHE" <<EOF
checked_at=1
repo=current
repo_tip=${shaB}
image=current
image_id=sha256:ccc
tag=latest
fingerprint=${shaB}:sha256:ccc
skip_key=
skip_until=0
EOF
: >"$CURL_LOG"
WEBTOP_LOGIN_ASSUME_INTERACTIVE=1 run motd </dev/null >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^image=behind$' "$WEBTOP_LOGIN_CACHE" && break
  sleep 0.2
done
grep -q '^image=behind$' "$WEBTOP_LOGIN_CACHE" || { cat "$WEBTOP_LOGIN_CACHE" >&2; fail "stale cache was not refreshed"; }
grep -q '^checked_at=1$' "$WEBTOP_LOGIN_CACHE" && fail "refresh kept the stale timestamp"
[[ -s "$CURL_LOG" ]] || fail "background refresh did not call curl"

# Hook install is idempotent and removable. A non-interactive shell stays quiet.
run login-check install >/dev/null
run login-check install >/dev/null
start_count=$(grep -c 'webtop-login-check start' "$WEBTOP_LOGIN_BASHRC")
[[ "$start_count" -eq 1 ]] || fail "bashrc hook installed ${start_count} times"
grep -q 'webtop-login-check' "$WEBTOP_LOGIN_PROFILE"
grep -q 'case $- in' "$WEBTOP_LOGIN_PROFILE"
bash -n "$WEBTOP_LOGIN_PROFILE"
hook_out=$(bash -c "source '$WEBTOP_LOGIN_PROFILE'" 2>&1 || true)
[[ -z "$hook_out" ]] || fail "non-interactive profile hook printed: $hook_out"
run login-check uninstall >/dev/null
[[ ! -e "$WEBTOP_LOGIN_PROFILE" ]] || fail "profile hook was not removed"
if grep -q 'webtop-login-check start' "$WEBTOP_LOGIN_BASHRC"; then
  fail "bashrc hook was not removed"
fi

printf 'ok\n'
