#!/usr/bin/env bash
# From the package root on Linux, run bash Tests/Support/LinuxClipboard/run.sh.
# Pass an existing SwiftPM build directory (swift build --show-bin-path) to reuse its C objects.
# Requires the normal Rune Linux build dependencies, clang, pkg-config, Cage,
# wtype, and Mesa's llvmpipe. The probe uses a private headless compositor.
set -eu

if [[ ${1:-} == --clients ]]; then
    [[ ${WLR_BACKENDS:-} == headless && -f clients.sh && -x probe && -n ${WAYLAND_DISPLAY:-} &&
        $WAYLAND_DISPLAY != */* && -S $PWD/$WAYLAND_DISPLAY && $XDG_RUNTIME_DIR == "$PWD" ]]
    unset DISPLAY
    pids=()
    trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done' EXIT
    "$RUNE_TEST_WTYPE" -s 40000 & pids+=("$!") # Provide a seat before either SDL window maps.
    for client in owner reader; do
        ./probe "$client" & pid=$!; pids+=("$pid")
        for state in focus write; do
            for ((i=0; i<300; i++)); do
                [[ ! -e $client.$state ]] || break
                kill -0 "$pid" 2>/dev/null || { wait "$pid"; exit 1; }
                sleep .05
            done
            [[ -e $client.$state ]] || { echo "Timed out waiting for $client $state" >&2; exit 1; }
            if [[ $state == focus ]]; then "$RUNE_TEST_WTYPE" -M shift -k a -m shift; fi
        done
    done
    wait "${pids[2]}"
    wait "${pids[1]}"
    touch passed
    exit 0
fi

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
keyboard=$(command -v wtype) || { echo 'Install wtype to run this test.' >&2; exit 1; }
command -v cage >/dev/null || { echo 'Install Cage to run this test.' >&2; exit 1; }
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -m 700 "$scratch/session"
if (( $# )); then
    out=$(cd "$1" && pwd)
else
    swift build --package-path "$root" --scratch-path "$scratch/build" --target CRuneDesktopServices -j 4
    out=$(swift build --package-path "$root" --scratch-path "$scratch/build" --show-bin-path)
fi
# Swift Build produces a combined object per target; the native SwiftPM engine
# puts its individual objects in target-specific directories.
if [[ -f "$out/CRuneDesktopServices.o" ]]; then
    ar rcs "$scratch/bridge.a" "$out/CRuneDesktopServices.o" "$out/CRuneLinuxA11y.o"
else
    ar rcs "$scratch/bridge.a" "$out/CRuneDesktopServices.build/"*.c.o "$out/CRuneLinuxA11y.build/"*.c.o
fi
# shellcheck disable=SC2046
clang -std=c11 -Wall -Wextra -Werror "$here/Probe.c" -I "$root/Sources/CRuneDesktopServices/include" \
    $(pkg-config --cflags sdl2) "$scratch/bridge.a" \
    $(pkg-config --libs sdl2 gtk+-3.0 atk-bridge-2.0 atspi-2 wayland-client xkbcommon xcb x11) \
    -o "$scratch/session/probe"
cp "$here/run.sh" "$scratch/session/clients.sh"
cd "$scratch/session"
runner=()
if (( EUID == 0 )); then
    chmod 711 "$scratch"
    chown -R nobody "$PWD"
    runner=(runuser -u nobody --)
fi
# Unset inherited sockets before starting the private compositor.
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET
"${runner[@]}" env XDG_RUNTIME_DIR="$PWD" XDG_CACHE_HOME="$PWD/cache" WLR_BACKENDS=headless \
    RUNE_TEST_WTYPE="$keyboard" \
    WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER_ALLOW_SOFTWARE=1 SDL_VIDEODRIVER=wayland \
    SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    cage -- bash ./clients.sh --clients >cage.log 2>&1 || { cat cage.log >&2; exit 1; }
[[ -f passed ]] || { cat cage.log >&2; exit 1; }
echo 'Wayland clipboard passed UTF-8, HTML, custom binary, concealment, and same-text owner replacement.'
