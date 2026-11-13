#!/bin/sh
# Regenerates precompiled Metal shader libraries (`.metallib`) and `manifest.tsv` FNV-64 hashes
# for Rune, RuneFX, and RuneLight across macOS, iOS, and iOS Simulator:
# - Sources/Rune/Resources/Metal/{macos,ios,ios_sim}/*.metallib
# - Sources/RuneFX/Resources/Metal/{macos,ios,ios_sim}/*.metallib
# - Sources/RuneLight/Resources/Metal/{macos,ios,ios_sim}/*.metallib
#
# App builds embed the committed `.metallib` resources via SwiftPM and do not run `xcrun` at build/launch time.
set -eu

cd "$(dirname "$0")/.."

if ! xcrun -sdk macosx --find metal >/dev/null 2>&1; then
    echo "error: xcrun -sdk macosx metal not found (install Xcode or Metal Toolchain)" >&2
    exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rune-metallib.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

dump_dir="$tmp/dump"
mkdir -p "$dump_dir"

if ! RUNE_DUMP_METALLIB_DIR="$dump_dir" xcrun swift test --filter "dumpBuiltinShadersForPrecompile" >"$tmp/dump.log" 2>&1; then
    cat "$tmp/dump.log" >&2
    exit 1
fi

compile_target() {
    key="$1"
    dest_root="$2"
    src_dir="$dump_dir/$key"
    if [ ! -d "$src_dir" ]; then
        echo "error: missing dumped MSL directory $src_dir" >&2
        exit 1
    fi

    rm -rf "$dest_root"
    mkdir -p "$dest_root"
    cp "$src_dir/manifest.tsv" "$dest_root/manifest.tsv"

    for spec in \
        "macosx:-std=metal3.0 -mmacosx-version-min=13.0 -fpreserve-invariance -Wno-unused-const-variable -Wno-unused-variable -O2:macos" \
        "iphoneos:-std=metal3.0 -mios-version-min=16.0 -fpreserve-invariance -Wno-unused-const-variable -Wno-unused-variable -O2:ios" \
        "iphonesimulator:-std=metal3.0 -mios-simulator-version-min=16.0 -fpreserve-invariance -Wno-unused-const-variable -Wno-unused-variable -O2:ios_sim"
    do
        sdk="${spec%%:*}"
        rest="${spec#*:}"
        flags="${rest%:*}"
        platform="${rest##*:}"

        if ! xcrun -sdk "$sdk" --find metal >/dev/null 2>&1; then
            echo "warning: skipping $sdk (metal compiler not available)" >&2
            continue
        fi

        air_dir="$tmp/air/$key/$platform"
        out_dir="$dest_root/$platform"
        mkdir -p "$air_dir" "$out_dir"

        for metal_file in "$src_dir"/*.metal; do
            [ -e "$metal_file" ] || continue
            base="$(basename "${metal_file%.metal}")"
            # shellcheck disable=SC2086
            xcrun -sdk "$sdk" metal $flags -c "$metal_file" -o "$air_dir/$base.air"
            xcrun -sdk "$sdk" metallib "$air_dir/$base.air" -o "$out_dir/$base.metallib"
        done
        echo "compiled $key/$platform ($(ls "$out_dir"/*.metallib | wc -l | tr -d ' ') metallibs)"
    done
}

compile_target "rune" "Sources/Rune/Resources/Metal"
compile_target "runefx" "Sources/RuneFX/Resources/Metal"
compile_target "runelight" "Sources/RuneLight/Resources/Metal"
