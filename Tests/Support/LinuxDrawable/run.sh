#!/usr/bin/env bash
# From the package root on Linux, run bash Tests/Support/LinuxDrawable/run.sh.
# Requires SDL2, Mesa OpenGL, Wayland, X11 development packages, clang, pkg-config and Xvfb.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

# shellcheck disable=SC2046
clang -std=c11 -Wall -Wextra -Werror \
    -I "$root/Sources/CRuneLinux/include" -I "$root/Sources/CRuneNotify/include" \
    "$here/Probe.c" "$root/Sources/CRuneLinux/RuneLinux.c" \
    "$root/Sources/CRuneLinux/LinuxWindowGeometry.c" "$root/Sources/CRuneLinux/LinuxNotificationWindow.c" \
    "$root/Sources/CRuneNotify/LinuxWindowFocus.c" \
    $(pkg-config --cflags --libs sdl2 wayland-client x11 xext x11-xcb xcb gl) -o "$scratch/probe"
SDL_VIDEODRIVER=x11 xvfb-run -a -s '-screen 0 1280x900x24 +extension GLX' "$scratch/probe"
