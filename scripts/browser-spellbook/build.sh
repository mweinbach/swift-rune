#!/usr/bin/env bash
# Rebuild the dictionary resource. Install the compiler and target with
# rustup toolchain install 1.97.0 --profile minimal --target wasm32-unknown-unknown
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
cache=${CARGO_HOME:-"$HOME/.cargo"}
build_dir=${CARGO_TARGET_DIR:-"$root/.build/browser-spellbook"}
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$cache=/cargo"$'\x1f'"--remap-path-prefix=$root=/rune"
cargo +1.97.0 build --locked --target wasm32-unknown-unknown --target-dir "$build_dir" --release
install -m 644 "$build_dir/wasm32-unknown-unknown/release/rune_spellbook.wasm" "$root/Sources/Rune/Resources/Web/rune-spellbook.wasm"
