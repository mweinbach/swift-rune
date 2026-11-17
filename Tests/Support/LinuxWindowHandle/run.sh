#!/usr/bin/env bash
# Run on Linux with SDL2, OpenGL, Wayland, X11/Xext/XTest/Xlib-xcb, clang,
# pkg-config, Xvfb and Weston. With Sway and Python 3 it also checks the tiler's
# placement decision. To check the Swift builder, set RUNE_FLOAT_APP to the
# FloatApp executable from swift build --package-path Tests/Support/LinuxWindowHandle.
# Install twm to exercise a reparented X11 window.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

for fixture in Probe Reparent Float; do
    clang -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
        -I "$root/Sources/CRuneLinux/include" -I "$root/Sources/CRuneNotify/include" \
        "$here/$fixture.c" "$root/Sources/CRuneLinux/"{RuneLinux,LinuxWindowGeometry,LinuxNotificationWindow}.c \
        "$root/Sources/CRuneNotify/LinuxWindowFocus.c" \
        $(pkg-config --cflags --libs sdl2 gl wayland-client x11 xext x11-xcb xcb xtst) -o "$scratch/$fixture"
done

xvfb-run -a -s '-screen 0 800x600x24 +extension GLX' bash -euo pipefail -s -- "$scratch" "$here" <<'SERVERS'
export XDG_RUNTIME_DIR=$1
export SDL_VIDEODRIVER=x11
"$1/Float"
if [[ $EUID != 0 ]] && command -v sway >/dev/null && command -v swaymsg >/dev/null; then
    python3 "$2/float-sway.py" "$1/Float"
    if [[ -n ${RUNE_FLOAT_APP:-} ]]; then python3 "$2/float-sway.py" "$RUNE_FLOAT_APP"; fi
fi
"$1/Reparent"
"$1/Probe"
if command -v twm >/dev/null; then
    printf '%s\n' RandomPlacement 'TitleFont "fixed"' 'MenuFont "fixed"' 'ResizeFont "fixed"' \
        'IconFont "fixed"' 'IconManagerFont "fixed"' > "$1/twmrc"
    twm -f "$1/twmrc" > "$1/twm.log" 2>&1 &
    wm=$!
    trap 'kill "$wm" 2>/dev/null || true' EXIT
    RUNE_TEST_DECORATED=1 "$1/Probe"
    kill "$wm"
    wait "$wm" || true
    trap - EXIT
fi
export WAYLAND_DISPLAY=rune-window-handle
weston -B x11 --renderer=pixman --shell=desktop-shell.so --no-config --width=320 --height=200 \
    --socket="$WAYLAND_DISPLAY" --idle-time=0 --log="$1/weston.log" &
weston=$!
trap 'kill "$weston" 2>/dev/null || true; wait "$weston" || true' EXIT
for ((i=0; i<100; i++)); do
    [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break
    sleep 0.05
done
output=$(sed -n 's/.*window id \([0-9]*\)$/\1/p' "$1/weston.log" | head -1)
[[ -n $output ]]
SDL_VIDEODRIVER=wayland "$1/Probe" "$output"
SDL_VIDEODRIVER=wayland "$1/Float"
SERVERS
