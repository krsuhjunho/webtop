#!/bin/bash
# X11 fallback. This image sets PIXELFLUX_WAYLAND=true, so the normal path
# is startwm_wayland.sh. Adapted from linuxserver/docker-webtop (GPL-3.0-only).

if [ ! -f "$HOME/.config/kwinrc" ]; then
  kwriteconfig6 --file "$HOME/.config/kwinrc" --group Compositing --key Enabled false
fi
if [ ! -f "$HOME/.config/kscreenlockerrc" ]; then
  kwriteconfig6 --file "$HOME/.config/kscreenlockerrc" --group Daemon --key Autolock false
fi

mkdir -p "${HOME}/.local/share"
touch "${HOME}/.local/share/user-places.xbel"

# shellcheck disable=SC1091
[ -r /etc/xdg/plasma-workspace/env/im.sh ] && . /etc/xdg/plasma-workspace/env/im.sh

exec dbus-launch --exit-with-session /usr/bin/startplasma-x11
