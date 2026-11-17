#!/usr/bin/env bash
# Run a real IBus preedit/commit through Rune TextEdit, then read the selection through X11.
# Requires Xvfb, xdotool, xclip, IBus, the m17n Hindi ITRANS engine and Python 3 with GI Atspi.
set -euo pipefail

if [[ ${1:-} != --private-session ]]; then
    binary=$(realpath "${1:?pass the path to rune-rich-clipboard}")
    exec xvfb-run -a -s '-screen 0 1024x768x24 +extension GLX' \
        dbus-run-session -- "$0" --private-session "$binary"
fi

binary=$2
runtime_dir=$(mktemp -d)
app_pid=
cleanup() {
    if [[ -n $app_pid ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    ibus exit 2>/dev/null || true
    rm -rf -- "$runtime_dir"
}
trap cleanup EXIT
export XDG_RUNTIME_DIR="$runtime_dir" XDG_CONFIG_HOME="$runtime_dir/config" XDG_CACHE_HOME="$runtime_dir/cache"
export RUNE_READY_DIR="$runtime_dir/ready" SDL_VIDEODRIVER=x11 RUNE_PLAYGROUND=0
export XMODIFIERS=@im=ibus SDL_IM_MODULE=ibus LANG=C.UTF-8
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_CACHE_HOME LANG XMODIFIERS
ibus-daemon --daemonize --xim --panel disable --emoji-extension disable
for ((i=0; i<150; i++)); do
    if ibus address | grep -q '^unix:' && ibus list-engine | grep 'm17n:hi:itrans' >/dev/null; then break; fi
    sleep 0.1
done
ibus list-engine | grep 'm17n:hi:itrans' >/dev/null

"$binary" & app_pid=$!
for ((i=0; i<300; i++)); do
    kill -0 "$app_pid"
    if compgen -G "$RUNE_READY_DIR/*" >/dev/null; then break; fi
    sleep 0.1
done
compgen -G "$RUNE_READY_DIR/*" >/dev/null
window=$(xdotool search --onlyvisible --name '^Rich Clipboard$' | tail -1)
xdotool windowfocus --sync "$window"
xdotool mousemove --window "$window" 46 48 click 1

expect_editor_text() {
    /usr/bin/python3 - "$1" <<'PY'
import sys
import time
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib

def descendants(node):
    if node:
        yield node
        for index in range(node.get_child_count()):
            yield from descendants(node.get_child_at_index(index))

deadline = time.monotonic() + 12
while time.monotonic() < deadline:
    for node in descendants(Atspi.get_desktop(0)):
        state = node.get_state_set()
        if state.contains(Atspi.StateType.EDITABLE) and state.contains(Atspi.StateType.FOCUSED):
            if Atspi.Text.get_text(node, 0, -1) == sys.argv[1]:
                sys.exit(0)
    while GLib.MainContext.default().iteration(False):
        pass
    time.sleep(0.05)
sys.exit(f"Focused editor text did not reach {sys.argv[1]!r}.")
PY
}
expect_editor_text ''
# Some IBus versions report an error even though switching succeeded. Verify the selected engine.
ibus engine m17n:hi:itrans || true
[[ $(ibus engine) == m17n:hi:itrans ]]
sleep 0.4
xdotool type --delay 90 namaste
xdotool key space
expect_editor_text 'नमस्ते '
ibus engine xkb:us::eng || true
sleep 0.5
xdotool key ctrl+a ctrl+c
for ((i=0; i<50; i++)); do
    value=$(timeout 1 xclip -selection clipboard -o 2>/dev/null || true)
    if [[ $value == 'नमस्ते ' ]]; then
        echo "IBus Hindi composition reached Rune TextEdit and the native clipboard."
        exit 0
    fi
    sleep 0.05
done
echo "Unexpected editor contents [$value]." >&2
exit 1
