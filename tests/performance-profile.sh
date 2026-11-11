#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/kwriteconfig6" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_LOG:?}"
EOF
chmod 755 "$tmp/kwriteconfig6"
export STUB_LOG="$tmp/low.log"
export HOME="$tmp/home"
export WEBTOP_PROFILE=low-power
mkdir -p "$HOME/.config"
PATH="$tmp:$PATH" bash "$ROOT/root/usr/local/bin/webtop-tune" wayland
grep -q -- '--file kdeglobals --group KDE --key AnimationDurationFactor 0' "$STUB_LOG"
grep -q -- '--file kwinrc --group Plugins --key blurEnabled false' "$STUB_LOG"
grep -q -- '--file kwinrc --group Compositing --key Enabled true' "$STUB_LOG"
grep -q -- '--file baloofilerc --group Basic Settings --key Indexing-Enabled false' "$STUB_LOG"
test -f "$HOME/.config/autostart/org.kde.kdeconnect.daemon.desktop"
grep -q 'Hidden=true' "$HOME/.config/autostart/org.kde.kdeconnect.daemon.desktop"

export STUB_LOG="$tmp/x11.log"
export WEBTOP_PROFILE=low-power
PATH="$tmp:$PATH" bash "$ROOT/root/usr/local/bin/webtop-tune" x11
grep -q -- '--file kwinrc --group Compositing --key Enabled false' "$STUB_LOG"

export STUB_LOG="$tmp/quality.log"
export WEBTOP_PROFILE=quality
PATH="$tmp:$PATH" bash "$ROOT/root/usr/local/bin/webtop-tune" wayland
grep -q -- '--file kdeglobals --group KDE --key AnimationDurationFactor 0.5' "$STUB_LOG"
grep -q -- '--file kwinrc --group Plugins --key blurEnabled true' "$STUB_LOG"

envfile="$ROOT/deploy/.env"
backup=""
if [[ -f "$envfile" ]]; then
  backup=$(mktemp)
  cp "$envfile" "$backup"
fi
cleanup_env() {
  if [[ -n "$backup" ]]; then
    cp "$backup" "$envfile"
    rm -f "$backup"
  else
    rm -f "$envfile"
  fi
}
trap 'cleanup_env; rm -rf "$tmp"' EXIT
if [[ ! -f "$envfile" ]]; then
  printf '%s\n' 'MAXMIND_ACCOUNT_ID=1' 'MAXMIND_LICENSE_KEY=dummy' \
    'CERTADMIN_PROXY_SECRET=0123456789abcdef0123456789abcdef' > "$envfile"
fi
bash "$ROOT/webtop.sh" profile balanced
grep -q '^WEBTOP_PROFILE=balanced$' "$envfile"
grep -q '^SELKIES_ENCODER=h264enc$' "$envfile"
grep -q '^SELKIES_FRAMERATE=30$' "$envfile"
grep -q '^SELKIES_AUDIO_ENABLED=true$' "$envfile"
bash "$ROOT/webtop.sh" profile low-power
grep -q '^WEBTOP_PROFILE=low-power$' "$envfile"
grep -q '^SELKIES_ENCODER=jpeg$' "$envfile"
grep -q '^SELKIES_FRAMERATE=30$' "$envfile"
grep -q '^WEBTOP_BRAVE_LOW_CPU=1$' "$envfile"
# An existing audio choice is kept when the profile changes.
sed -i 's/^SELKIES_AUDIO_ENABLED=.*/SELKIES_AUDIO_ENABLED=false/' "$envfile"
bash "$ROOT/webtop.sh" profile quality
grep -q '^SELKIES_AUDIO_ENABLED=false$' "$envfile"
grep -q '^SELKIES_FRAMERATE=60$' "$envfile"
# Kasm ignores Selkies encoder knobs.
bash "$ROOT/webtop.sh" variant kasm
grep -q '^WEBTOP_VARIANT=kasm$' "$envfile"
grep -q '^IMAGE_TAG=kasm$' "$envfile"
encoder_before=$(grep '^SELKIES_ENCODER=' "$envfile")
out=$(bash "$ROOT/webtop.sh" profile balanced 2>&1)
printf '%s\n' "$out" | grep -q 'Selkies 전용'
grep -q "^${encoder_before}$" "$envfile"
grep -q '^WEBTOP_PROFILE=quality$' "$envfile"
bash "$ROOT/webtop.sh" variant selkies
grep -q '^WEBTOP_VARIANT=selkies$' "$envfile"
grep -q '^IMAGE_TAG=latest$' "$envfile"
echo "performance profile ok"
