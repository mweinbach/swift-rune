#!/usr/bin/env bash
# run.sh --primary starts this within its own Xvfb or Sway session.
set -eu
pids=()
cleanup() {
    local status=$?
    if (( status != 0 )) && [[ -e probe.log ]]; then tail -70 probe.log >&2; fi
    for pid in "${pids[@]}"; do kill -CONT "$pid" 2>/dev/null || :; kill "$pid" 2>/dev/null || :; done
    if [[ $SDL_VIDEODRIVER == wayland ]]; then swaymsg exit >/dev/null; fi
}
trap cleanup EXIT

wait_for() {
    for ((i=0; i<200; i++)); do
        [[ ! -e $1 ]] || return 0
        kill -0 "$probe" || return 1
        sleep .02
    done
    echo "Timed out waiting for $1 on $SDL_VIDEODRIVER" >&2
    return 1
}

read_primary() {
    if [[ $SDL_VIDEODRIVER == wayland ]]; then wl-paste -np -t 'text/plain;charset=utf-8'
    else xclip -selection primary -o -t UTF8_STRING
    fi
}

if [[ $SDL_VIDEODRIVER == wayland ]]; then
    [[ $WLR_BACKENDS == headless && -S $PWD/$WAYLAND_DISPLAY && $XDG_RUNTIME_DIR == "$PWD" ]]
    unset DISPLAY
    "$RUNE_TEST_WTYPE" -s 20000 & pids+=("$!")
fi
protocol=${RUNE_TEST_PRIMARY_PROTOCOL:-}
probe_env=()
if [[ -n $protocol ]]; then
    probe_env=(LD_PRELOAD="$PWD/globals.so" WAYLAND_DEBUG=client)
    if [[ $protocol == wlr-v1 ]]; then probe_env+=(RUNE_TEST_PRIMARY_MISSING=1); fi
fi
env "${probe_env[@]}" ./probe primary 2>probe.log & probe=$!
pids+=("$probe")
if [[ $SDL_VIDEODRIVER == x11 ]]; then
    id=$(xdotool search --sync --onlyvisible --name '^primary$' | head -n1)
    xdotool windowfocus --sync "$id"
fi
wait_for primary.focus
if [[ $SDL_VIDEODRIVER == wayland ]]; then "$RUNE_TEST_WTYPE" -k a; else xdotool key a; fi
wait_for primary.write

printf 'Rune\0selection\n🦊' >rune.expected
printf 'other\0selection\n猫' >external.expected
printf 'Rune 🦊' >regular.expected
if [[ $protocol == wlr-v1 ]]; then
    if read_primary >actual 2>/dev/null; then [[ ! -s actual ]]; fi
else
    read_primary >actual && cmp rune.expected actual
fi
if [[ $SDL_VIDEODRIVER == wayland ]]; then
    wl-paste -n -t text/plain >actual
    wl-copy -p --foreground -t 'text/plain;charset=utf-8' <external.expected & provider=$!
else
    xclip -selection clipboard -o -t UTF8_STRING >actual
    xclip -quiet -selection primary -i -t UTF8_STRING <external.expected 2>provider.log & provider=$!
fi
pids+=("$provider")
cmp regular.expected actual
for ((i=0; i<100; i++)); do
    if read_primary >actual 2>/dev/null && cmp -s external.expected actual; then break; fi
    sleep .02
done
cmp external.expected actual

# The owner can be slow. The Rune input thread must return before it replies.
kill -STOP "$provider"
touch external.write
wait_for primary.requested
kill -CONT "$provider"
wait "$probe"
if [[ $protocol == ext_data_control_manager_v1 || $protocol == zwlr_data_control_manager_v1 ]]; then
    grep -Eq "${protocol%manager_v1}device_v1[@#][0-9]+\\.set_primary_selection\\(" probe.log
elif [[ $protocol == wlr-v1 ]]; then
    grep -Fq 'Probe advertised zwlr_data_control_manager_v1 version 1' probe.log
fi
read_primary >actual
cmp external.expected actual
touch primary.passed
