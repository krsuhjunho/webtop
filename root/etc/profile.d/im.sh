#!/bin/sh
# Login shells (Konsole) pick these up even if the desktop env was sanitized.
export GTK_IM_MODULE="${GTK_IM_MODULE:-fcitx}"
export QT_IM_MODULE="${QT_IM_MODULE:-fcitx}"
export QT_IM_MODULES="${QT_IM_MODULES:-wayland;fcitx}"
export XMODIFIERS="${XMODIFIERS:-@im=fcitx}"
export SDL_IM_MODULE="${SDL_IM_MODULE:-fcitx}"
export INPUT_METHOD="${INPUT_METHOD:-fcitx}"
export GLFW_IM_MODULE="${GLFW_IM_MODULE:-ibus}"
export XKB_DEFAULT_RULES="${XKB_DEFAULT_RULES:-evdev}"
export XKB_DEFAULT_MODEL="${XKB_DEFAULT_MODEL:-pc105}"
export XKB_DEFAULT_LAYOUT="${XKB_DEFAULT_LAYOUT:-kr}"
export TZ="${TZ:-Asia/Tokyo}"
