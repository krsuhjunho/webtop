#!/usr/bin/env python3
# Adapted from linuxserver/docker-webtop (ubuntu-kde), GPL-3.0-only.
# Binds the X11 socket so XWayland lands on the DISPLAY kwin was given.
import os
import socket

display_env = os.environ.get("DISPLAY", ":1")
display_num = display_env.lstrip(":")
path = f"/tmp/.X11-unix/X{display_num}"

if os.path.exists(path):
    os.remove(path)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(path)
sock.listen(128)

fd = sock.fileno()
os.set_inheritable(fd, True)

os.execlp(
    "kwin_wayland",
    "kwin_wayland",
    "--no-lockscreen",
    "--xwayland",
    f"--xwayland-display=:{display_num}",
    f"--xwayland-fd={fd}",
)
