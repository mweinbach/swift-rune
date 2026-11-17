#!/usr/bin/env bash
# From the package root on Linux, run bash Tests/Support/LinuxClipboard/run.sh.
# Pass an existing SwiftPM build directory (swift build --show-bin-path) to reuse its C objects.
# Requires the normal Rune Linux build dependencies, clang, pkg-config, Cage,
# wtype, and Mesa's llvmpipe. The probe uses a private headless compositor.
# --primary checks X11 and Wayland against xclip and wl-clipboard, and also
# requires Xvfb, xdotool, and Sway. --primary-wlr and --primary-ext restrict the
# probe to the respective data-control protocol. --primary-wlr-v1 tests a
# compositor offering only the earlier, regular-clipboard-only version.
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
primary=0
protocol=
case ${1:-} in
    --primary) primary=1 ;;
    --primary-ext) primary=1; protocol=ext_data_control_manager_v1 ;;
    --primary-wlr) primary=1; protocol=zwlr_data_control_manager_v1 ;;
    --primary-wlr-v1) primary=1; protocol=wlr-v1 ;;
esac
if (( primary )); then
    shift
    clients=(wl-copy wl-paste sway swaymsg)
    if [[ -z $protocol ]]; then clients+=(xclip xvfb-run xdotool); fi
    for client in "${clients[@]}"; do command -v "$client" >/dev/null; done
fi
keyboard=$(command -v wtype) || { echo 'Install wtype to run this test.' >&2; exit 1; }
if (( ! primary )); then command -v cage >/dev/null || { echo 'Install Cage to run this test.' >&2; exit 1; }; fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -m 700 "$scratch/session"
if (( $# )); then
    out=$(cd "$1" && pwd)
else
    swift build --package-path "$root" --scratch-path "$scratch/build" --target CRuneDesktopServices -j 3
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
if (( primary )); then
    cp "$here/primary-clients.sh" "$scratch/session/clients.sh"
    if [[ -n $protocol ]]; then
        clang -shared -fPIC -Wall -Wextra -Werror "$here/WaylandGlobals.c" \
            $(pkg-config --cflags --libs wayland-client) -ldl -o "$scratch/session/globals.so"
    fi
else
    cp "$here/run.sh" "$scratch/session/clients.sh"
fi
cd "$scratch/session"
runner=()
if (( EUID == 0 )); then
    chmod 711 "$scratch"
    chown -R nobody "$PWD"
    runner=(runuser -u nobody --)
fi
# Unset inherited sockets before starting the private compositor.
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET
if (( primary )) && [[ -z $protocol ]]; then
    mkdir -m 700 "$scratch/x11"
    cp probe clients.sh "$scratch/x11/"
    if (( EUID == 0 )); then chown -R nobody "$scratch/x11"; fi
    (cd "$scratch/x11" && "${runner[@]}" env XDG_RUNTIME_DIR="$PWD" SDL_VIDEODRIVER=x11 \
        XDG_CACHE_HOME="$PWD/cache" GDK_BACKEND=x11 xvfb-run -a timeout 30 bash ./clients.sh && test -f primary.passed)
fi
if (( primary )); then
    printf '%s\n' 'xwayland disable' 'output * mode 800x600' 'exec bash ./clients.sh' >sway.conf
    compositor=(sway -c "$PWD/sway.conf")
else
    compositor=(cage -- bash ./clients.sh --clients)
fi
"${runner[@]}" env XDG_RUNTIME_DIR="$PWD" XDG_CACHE_HOME="$PWD/cache" WLR_BACKENDS=headless \
    RUNE_TEST_WTYPE="$keyboard" RUNE_TEST_PRIMARY_PROTOCOL="$protocol" \
    WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER_ALLOW_SOFTWARE=1 SDL_VIDEODRIVER=wayland \
    SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    timeout 50 "${compositor[@]}" >cage.log 2>&1 || { cat cage.log >&2; exit 1; }
if (( primary )); then
    [[ -f primary.passed ]] || { cat cage.log >&2; exit 1; }
    if [[ -n $protocol ]]; then echo "Wayland PRIMARY passed restricted registry test ($protocol)."
    else echo 'X11 and Wayland PRIMARY passed bidirectional UTF-8 with embedded NUL, slow external owner and independent secret clipboard expiry.'
    fi
    exit 0
fi
[[ -f passed ]] || { cat cage.log >&2; exit 1; }
echo 'Wayland clipboard passed UTF-8, HTML, custom binary, concealment, and same-text owner replacement.'
