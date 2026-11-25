#!/usr/bin/env bash
set -eu
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <swift-sdk> <executable-product> [swift build options...]" >&2
    exit 2
fi
sdk=$1
product=$2
shift 2
swift=(swift)
if [[ $(uname -s) == Darwin ]]; then
    swift=(xcrun swift)
fi
# Layout walks have nested Swift value types and exceed wasm-ld's 64 KiB default stack.
flags=(-Xcc -DRUNE_BROWSER_TEXT -Xswiftc -DRUNE_BROWSER_TEXT
       -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor -Xlinker -z -Xlinker stack-size=8388608)
# SwiftPM defaults to debug. Keep its symbol names for browser stack traces.
configuration=debug
previous=
for option in "$@"; do
    case "$previous" in
        -c|--configuration) configuration=$option ;;
    esac
    case "$option" in
        --configuration=*) configuration=${option#*=} ;;
    esac
    previous=$option
done
if [[ $configuration == release ]]; then
    # Keep Rune's four-wide geometry and color operations as WebAssembly SIMD and
    # let browser apps specialize Rune's layout and frame code for their state type.
    flags+=(-Xcc -msimd128 -Xswiftc -enable-cmo-everything -Xlinker --strip-all)
fi
exports=(
    __main_void rune_web_enable rune_web_config rune_web_window_title rune_web_window_height rune_web_page rune_web_full_window rune_web_reset_renderer rune_web_buffer rune_web_fonts_changed rune_web_spelling_changed
    rune_web_next_wake rune_web_event rune_web_field rune_web_cursor rune_web_clipboard rune_web_popup rune_web_secondary_claim rune_web_accessibility rune_web_enable_accessibility_patches rune_web_flush_accessibility rune_web_idle_text
    rune_web_cpu_frame rune_web_cpu_rect
    rune_web_frame rune_web_scene rune_web_enable_atlas_patches rune_web_enable_image_pages rune_web_enable_glyph_pages rune_web_enable_cycle_patches rune_web_cached_layers rune_web_ui_passes
    rune_web_surface_submission rune_web_surface_complete
    rune_web_image_enable rune_web_image_next rune_web_image_apng rune_web_image_frame rune_web_image_finish
    rune_web_dispose
)
for symbol in "${exports[@]}"; do
    flags+=(-Xlinker "--export=$symbol")
done
"${swift[@]}" build --swift-sdk "$sdk" --product "$product" "${flags[@]}" "$@"
