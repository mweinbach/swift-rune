#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
: "${ndk:?Set ANDROID_NDK_HOME to the Android NDK directory}"
adb_cmd=(adb)
if [[ -n ${ANDROID_SERIAL:-} ]]; then adb_cmd+=(-s "$ANDROID_SERIAL"); fi
abi=$("${adb_cmd[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
case "$abi" in
  arm64-v8a) triple=aarch64-linux-android ;;
  x86_64) triple=x86_64-linux-android ;;
  armeabi-v7a) triple=armv7a-linux-androideabi ;;
  x86) triple=i686-linux-android ;;
  *) echo "Unsupported Android ABI $abi" >&2; exit 1 ;;
esac
compilers=("$ndk"/toolchains/llvm/prebuilt/*/bin/"${triple}26-clang")
scratch=$(mktemp -d)
remote=
cleanup() {
    if [[ $remote == /data/local/tmp/rune-egl-completion.* ]]; then "${adb_cmd[@]}" shell rm -rf "$remote"; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
"${compilers[0]}" -std=c11 -O2 -I"$repo/Sources/CRuneGL/include" "$here/Probe.c" \
    "$repo"/Sources/CRuneGL/*.c -o "$scratch/probe" -lEGL -lGLESv3 -ldl -lm -pthread
remote=$("${adb_cmd[@]}" shell mktemp -d /data/local/tmp/rune-egl-completion.XXXXXX | tr -d '\r')
"${adb_cmd[@]}" push "$scratch/probe" "$repo/Sources/Rune/Resources/GL/fullscreen.vert" "$repo/Sources/Rune/Resources/GL/layer.frag" "$remote/" >/dev/null
"${adb_cmd[@]}" shell chmod 700 "$remote/probe"
"${adb_cmd[@]}" shell "$remote/probe" "$remote/fullscreen.vert" "$remote/layer.frag"
