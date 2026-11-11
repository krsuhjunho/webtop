#!/bin/bash
# XFCE on KasmVNC (X11). fcitx5 is the input method; there is no KWin.

# shellcheck disable=SC1091
[ -r /etc/profile.d/im.sh ] && . /etc/profile.d/im.sh

if [ ! -d "${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml" ]; then
  mkdir -p "${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
  cp /defaults/xfce/*.xml "${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/"
fi

if [ ! -f "${HOME}/.config/xfce4/terminal/terminalrc" ]; then
  mkdir -p "${HOME}/.config/xfce4/terminal"
  cp /defaults/xfce/terminalrc "${HOME}/.config/xfce4/terminal/terminalrc"
fi

setxkbmap -rules "${XKB_DEFAULT_RULES:-evdev}" \
  -model "${XKB_DEFAULT_MODEL:-pc105}" \
  -layout "${XKB_DEFAULT_LAYOUT:-kr}" || true

# The base image collapses LANGUAGE to the first tag (ko_KR). Restore the
# Korean/Japanese fallback chain unless the user set their own list.
case "${LANGUAGE:-}" in
  *:*) ;;
  *) export LANGUAGE="ko_KR:ko:ja_JP:ja:en" ;;
esac

# fcitx5 is started by the session autostart, after this bus exists.
# Launching it here, before xfce4-session, makes dbus-launch drop the bus.
exec dbus-launch /usr/bin/xfce4-session
