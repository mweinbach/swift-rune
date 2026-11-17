#!/bin/zsh
# Run on a booted iOS simulator. Optionally reuse an existing SwiftPM simulator product directory.
# zsh Tests/Support/UIKitAccessibility/run.zsh <simulator-UDID> [Debug-iphonesimulator]
set -eu
if (( $# < 1 || $# > 2 )); then
    print -u2 "Usage: $0 <booted-simulator-UDID> [Debug-iphonesimulator]"
    exit 2
fi
device=$1
root=${0:A:h:h:h:h}
work=$(mktemp -d "${TMPDIR:-/tmp}/rune-uikit-accessibility.XXXXXX")
trap 'rm -rf "$work"' EXIT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
developer=$(xcrun --sdk iphonesimulator --show-sdk-platform-path)/Developer
target="$(uname -m)-apple-ios17.0-simulator"
if (( $# == 2 )); then
    products=${2:A}
else
    xcrun swift build --package-path "$root" --scratch-path "$work/build" --build-system swiftbuild \
        --sdk "$sdk" --triple "$target" --target Rune -j 2
    products="$work/build/out/Products/Debug-iphonesimulator"
fi
moduleMap="${products:h:h}/Intermediates.noindex/GeneratedModuleMaps-iphonesimulator/CRuneDesktopText.modulemap"
plugins="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
cat > "$work/Runner.swift" <<'SWIFT'
import Testing
@main struct AccessibilityTests {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
SWIFT
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 6 -sdk "$sdk" -target "$target" \
    -I "$products" -Xcc "-fmodule-map-file=$moduleMap" -F "$developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$developer/Library/Frameworks" -plugin-path "$plugins" \
    "$root"/Tests/RuneTests/{A11yPresentationTests,IOSHostTouchTests,RuneTestKey}.swift "$work/Runner.swift" \
    "$products"/{Rune,RuneRef,RuneMotion,RuneTaffy,CRuneDesktopText}.o -framework UIKit -framework Metal \
    -framework QuartzCore -o "$work/AccessibilityTests"
export SIMCTL_CHILD_PACKAGE_RESOURCE_BUNDLE_PATH="$products"
export SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$developer/Library/Frameworks"
export SIMCTL_CHILD_DYLD_LIBRARY_PATH="$developer/usr/lib"
simctl=${RUNE_SIMCTL:-$(xcrun --find simctl)}
"$simctl" spawn "$device" "$work/AccessibilityTests" --no-parallel \
    --filter 'uiKit(Exposes|DataTable)|activeTreeRowFocus|minimumAuthoredSetPosition'
