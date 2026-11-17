#!/usr/bin/env bash
# Requires clang, SDL2, EGL, libepoxy, Xvfb, xauth and Weston. To also exercise
# the Swift host, set RUNE_SURFACE_APP to the SurfaceApp built from this package.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
clang -std=c11 -D_POSIX_C_SOURCE=200809L -I"$root/Sources/CRuneGL/include" \
    "$here/Probe.c" "$root"/Sources/CRuneGL/*.c \
    $(pkg-config --cflags --libs sdl2 epoxy egl gl) -pthread -lm -ldl -o "$scratch/probe"

xvfb-run -a -s '-screen 0 640x480x24 +extension GLX' bash -euo pipefail -s -- \
    "$scratch" "$root/Sources/Rune/Resources/GL" <<'SERVERS'
export XDG_RUNTIME_DIR=$1
probe=$1/probe
shaders=("$2/fullscreen.vert" "$2/layer.frag")
SDL_VIDEODRIVER=x11 timeout 30 "$probe" glx "${shaders[@]}"
if [[ -n ${RUNE_SURFACE_APP:-} ]]; then SDL_VIDEODRIVER=x11 timeout 30 "$RUNE_SURFACE_APP"; fi
export WAYLAND_DISPLAY=rune-surface-completion
weston -B headless --renderer=pixman --no-config --idle-time=0 --socket="$WAYLAND_DISPLAY" --log="$1/weston.log" &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" || true' EXIT
for ((i=0; i<100; i++)); do
    [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break
    sleep 0.05
done
[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] || { cat "$1/weston.log"; exit 1; }
for api in egl gles; do
    SDL_VIDEODRIVER=wayland timeout 30 "$probe" "$api" "${shaders[@]}"
done
if [[ -n ${RUNE_SURFACE_APP:-} ]]; then SDL_VIDEODRIVER=wayland timeout 30 "$RUNE_SURFACE_APP"; fi
SERVERS
