#!/usr/bin/env bash
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <swift-sdk> <executable-product>" >&2
    exit 2
fi
sdk=$1
product=$2
flags=(-Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor)
for symbol in __main_void rune_web_enable rune_web_buffer rune_web_event rune_web_field rune_web_frame rune_web_dispose; do
    flags+=(-Xlinker "--export=$symbol")
done
xcrun swift build --swift-sdk "$sdk" --product "$product" "${flags[@]}"
