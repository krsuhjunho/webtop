#!/bin/bash
# KDE Plasma on nested KWin, adapted from linuxserver/docker-webtop
# (ubuntu-kde, GPL-3.0-only). Adds fcitx5 as KWin's virtual keyboard so
# Korean (hangul) and Japanese (mozc) preedit works inside the session.

ulimit -c 0

# shellcheck disable=SC1091
if [ -r /etc/xdg/plasma-workspace/env/im.sh ]; then
  . /etc/xdg/plasma-workspace/env/im.sh
fi

if [ ! -f "$HOME/.config/kwinrc" ]; then
  kwriteconfig6 --file "$HOME/.config/kwinrc" --group Compositing --key Enabled false
fi
if [ ! -f "$HOME/.config/kscreenlockerrc" ]; then
  kwriteconfig6 --file "$HOME/.config/kscreenlockerrc" --group Daemon --key Autolock false
fi

# KWin must launch fcitx5 itself (virtual keyboard) for Wayland text-input.
# Set this before kwin_wayland starts. Skip if the user already chose one.
IM_DESKTOP=""
for candidate in \
  /usr/share/applications/org.fcitx.Fcitx5.desktop \
  /usr/share/applications/fcitx5.desktop
do
  if [ -f "$candidate" ]; then
    IM_DESKTOP=$candidate
    break
  fi
done
if [ -n "$IM_DESKTOP" ]; then
  current_im=$(kreadconfig6 --file "$HOME/.config/kwinrc" --group Wayland --key InputMethod 2>/dev/null || true)
  if [ -z "$current_im" ]; then
    kwriteconfig6 --file "$HOME/.config/kwinrc" --group Wayland --key InputMethod "$IM_DESKTOP"
  fi
fi

# Match the capture compositor. XKB_DEFAULT_LAYOUT=kr is QWERTY plus Hangul/Hanja.
if [ ! -f "$HOME/.config/kxkbrc" ]; then
  kwriteconfig6 --file "$HOME/.config/kxkbrc" --group Layout --key Use true
  kwriteconfig6 --file "$HOME/.config/kxkbrc" --group Layout --key LayoutList "${XKB_DEFAULT_LAYOUT:-kr}"
  kwriteconfig6 --file "$HOME/.config/kxkbrc" --group Layout --key Model "${XKB_DEFAULT_MODEL:-pc105}"
fi

setterm blank 0 || true
setterm powerdown 0 || true

KWIN_RULES_FILE="$HOME/.config/kwinrulesrc"
RULE_DESC="wl-clipboard support"
if ! grep -q "$RULE_DESC" "$KWIN_RULES_FILE" 2>/dev/null; then
  if command -v uuidgen >/dev/null 2>&1; then
    RULE_ID=$(uuidgen)
  else
    RULE_ID=$(cat /proc/sys/kernel/random/uuid)
  fi
  count=$(kreadconfig6 --file "$KWIN_RULES_FILE" --group General --key count --default 0)
  new_count=$((count + 1))
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group General --key count "$new_count"
  existing_rules=$(kreadconfig6 --file "$KWIN_RULES_FILE" --group General --key rules)
  if [ -z "$existing_rules" ]; then
    kwriteconfig6 --file "$KWIN_RULES_FILE" --group General --key rules "$RULE_ID"
  else
    kwriteconfig6 --file "$KWIN_RULES_FILE" --group General --key rules "$existing_rules,$RULE_ID"
  fi
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key Description "$RULE_DESC"
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key wmclass "wl-(copy|paste)"
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key wmclassmatch 3
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key skiptaskbar --type bool "true"
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key skiptaskbarrule 2
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key skipswitcher --type bool "true"
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key skipswitcherrule 2
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key fsplevel 3
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key fsplevelrule 2
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key noborder --type bool "true"
  kwriteconfig6 --file "$KWIN_RULES_FILE" --group "$RULE_ID" --key noborderrule 2
fi

mkdir -p "${HOME}/.config/autostart" "${HOME}/.XDG" "${HOME}/.local/share/" "${HOME}/logs"
chmod 700 "${HOME}/.XDG"
touch "${HOME}/.local/share/user-places.xbel"
if ! mkdir -p /tmp/.X11-unix 2>/dev/null || ! chmod 1777 /tmp/.X11-unix 2>/dev/null; then
  sudo mkdir -p /tmp/.X11-unix
  sudo chmod 1777 /tmp/.X11-unix
fi

STARTUP_FILE="${HOME}/.config/autostart/autostart.desktop"
if [ ! -f "${STARTUP_FILE}" ]; then
  cat > "$STARTUP_FILE" <<'EOF'
[Desktop Entry]
Exec=bash /config/.config/openbox/autostart
Icon=dialog-scripts
Name=autostart
Path=
Type=Application
X-KDE-AutostartScript=true
EOF
  chmod +x "$STARTUP_FILE"
fi

export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_TYPE=wayland
export XDG_MENU_PREFIX=plasma-
export KDE_FULL_SESSION=true
export KDE_SESSION_VERSION=6
KDE_SESSION_UID="$(id -u)"
export KDE_SESSION_UID
export QT_QPA_PLATFORM=wayland
export DISPLAY=:1
export MOZ_ENABLE_WAYLAND=0
export KWIN_WAYLAND_NO_PERMISSION_CHECKS=1
XCURSOR_THEME=$(kreadconfig6 --file kcminputrc --group Mouse --key cursorTheme --default breeze_cursors)
XCURSOR_SIZE=$(kreadconfig6 --file kcminputrc --group Mouse --key cursorSize --default 24)
export XCURSOR_THEME XCURSOR_SIZE
if [ "${PELORUS,,}" = "true" ]; then
  export QT_ACCESSIBILITY=1
  export QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
  export GTK_MODULES=gail:atk-bridge
fi

for ENV_SCRIPT in /etc/xdg/plasma-workspace/env/*.sh "${HOME}"/.config/plasma-workspace/env/*.sh; do
  if [ -r "${ENV_SCRIPT}" ]; then
    # shellcheck disable=SC1090
    . "${ENV_SCRIPT}"
  fi
done

mkdir -p "${HOME}/.config/kdedefaults"
export XDG_CONFIG_DIRS="${HOME}/.config/kdedefaults:${XDG_CONFIG_DIRS:-/etc/xdg}"

kbuildsycoca6 || true

start_session() {
  WAYLAND_DISPLAY=wayland-1 python3 /kwin-xwayland.py &
  KWIN_PID=$!
  for _ in $(seq 1 100); do
    if [ -S "${XDG_RUNTIME_DIR}/wayland-0" ]; then
      break
    fi
    sleep 0.1
  done
  export WAYLAND_DISPLAY=wayland-0
  dbus-update-activation-environment --all || true

  # KWin's virtual-keyboard setting should have spawned fcitx5. If it did
  # not, start it so every session still has hangul and mozc.
  for _ in $(seq 1 30); do
    if pgrep -x fcitx5 >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if ! pgrep -x fcitx5 >/dev/null 2>&1; then
    fcitx5 -d --replace >/dev/null 2>&1 || true
  fi

  pipewire &
  for _ in $(seq 1 100); do
    if [ -S "${XDG_RUNTIME_DIR}/pipewire-0" ]; then
      break
    fi
    sleep 0.1
  done
  LD_PRELOAD= wireplumber &
  kcminit_startup || true
  kded6 &
  if [ "${PELORUS,,}" = "true" ]; then
    dbus-send --session --dest=org.a11y.Bus --type=method_call \
      --print-reply /org/a11y/bus org.freedesktop.DBus.Properties.Set \
      string:org.a11y.Status string:IsEnabled variant:boolean:true 2>/dev/null || true
    pelorus &
  fi
  xembedsniproxy &
  plasmashell &
  PLASMA_PID=$!
  for _ in $(seq 1 300); do
    if dbus-send --session --print-reply --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
      string:org.kde.plasmashell 2>/dev/null | grep -q true; then
      break
    fi
    sleep 0.1
  done
  xdg-user-dirs-update || true
  gmenudbusmenuproxy &
  xhost +si:localuser:root >/dev/null 2>&1 || true
  for ENTRY in "${HOME}"/.config/autostart/*.desktop; do
    if [ ! -f "${ENTRY}" ] || grep -q "^Hidden=true" "${ENTRY}"; then
      continue
    fi
    ENTRY_CMD=$(grep -m1 "^Exec=" "${ENTRY}" | cut -d= -f2- | sed 's/ %[a-zA-Z]//g')
    if [ -n "${ENTRY_CMD}" ]; then
      bash -c "${ENTRY_CMD}" &
    fi
  done
  wait "${PLASMA_PID}"
  kill "${KWIN_PID}" 2>/dev/null || true
}

LOG="${HOME}/logs/session.log"
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 5000000 ]; then
  mv "$LOG" "${LOG}.1"
fi
dbus-run-session bash -c "$(declare -f start_session); start_session" >> "$LOG" 2>&1
