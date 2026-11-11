#!/usr/bin/env bash
# VLC stays the video/audio default without dropping unrelated mime entries.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mime="$ROOT/root/usr/local/bin/webtop-mime"

cat > "$tmp/old.list" <<'EOF'
[Default Applications]
text/html=firefox.desktop
video/mp4=org.gnome.Totem.desktop
video/x-matroska=smplayer.desktop
image/png=ristretto.desktop

[Added Associations]
text/html=firefox.desktop;
video/mp4=org.gnome.Totem.desktop;vlc.desktop;
audio/mpeg=audacious.desktop;

[Removed Associations]
video/webm=vlc.desktop;
image/png=gwenview.desktop;
EOF

python3 "$mime" "$tmp/old.list"
python3 "$mime" "$tmp/old.list"

grep -q '^text/html=firefox.desktop$' "$tmp/old.list"
grep -q '^image/png=ristretto.desktop$' "$tmp/old.list"
grep -q '^video/mp4=vlc.desktop$' "$tmp/old.list"
grep -q '^video/x-matroska=vlc.desktop$' "$tmp/old.list"
grep -q '^video/x-flv=vlc.desktop$' "$tmp/old.list"
grep -q '^video/3gpp=vlc.desktop$' "$tmp/old.list"
grep -q '^audio/mpeg=vlc.desktop$' "$tmp/old.list"
grep -q '^audio/x-wav=vlc.desktop$' "$tmp/old.list"
grep -q '^video/mp4=vlc.desktop;org.gnome.Totem.desktop;$' "$tmp/old.list"
grep -q '^audio/mpeg=vlc.desktop;audacious.desktop;$' "$tmp/old.list"
grep -q '^image/png=gwenview.desktop;$' "$tmp/old.list"
if grep -q '^video/webm=vlc.desktop;' "$tmp/old.list" && grep -q 'Removed Associations' -A 20 "$tmp/old.list" | grep -q '^video/webm='; then
  echo "vlc stayed in Removed Associations" >&2
  exit 1
fi
# A second run does not duplicate association entries.
count=$(grep -c '^video/mp4=' "$tmp/old.list")
[[ "$count" -eq 2 ]]

python3 "$mime" "$tmp/fresh.list"
grep -q '^video/mp4=vlc.desktop$' "$tmp/fresh.list"
grep -q '^audio/flac=vlc.desktop$' "$tmp/fresh.list"
echo "mime defaults ok"
