#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
fixtures=Tests/Support/GPUSelection
compiler=${CC:-clang}
"$compiler" -std=c11 -Wall -Wextra -Werror "$fixtures/Policy.c" -o "$scratch/policy"
"$scratch/policy"
case $(uname -s) in
Darwin)
  xcrun swiftc -parse-as-library Sources/Rune/GPU/MetalAdapterPicker.swift "$fixtures/Metal.swift" -o "$scratch/metal"
  "$scratch/metal"
  "$scratch/metal" --named
  WGPU_POWER_PREF=high WGPU_ADAPTER_NAME=no-such-rune-gpu "$scratch/metal"
  ;;
Linux)
  "$compiler" -std=c11 -D_DEFAULT_SOURCE -ffunction-sections -fdata-sections -Wl,--gc-sections \
    -ISources/CRuneGPUSelection/include -ISources/CRuneOffscreenGL/include -ISources/CRuneGL/include \
    "$fixtures/LinuxEGL.c" Sources/CRuneGPUSelection/LinuxDevice.c Sources/CRuneOffscreenGL/Context.c \
    Sources/CRuneGL/{pass,pass_timer,renderer}.c -lEGL -lGLESv2 -ldl -lwayland-client -lm -pthread -o "$scratch/egl"
  "$scratch/egl"
  ;;
esac
