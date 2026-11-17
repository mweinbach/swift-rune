#!/bin/sh
# sh build-rust-peer.sh /path/to/anomalyco/rune /path/to/peer [rustc options]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
upstream=$1
output=$2
shift 2
rev=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["syncedCommit"])' "$here/../../../.upstream-sync.json")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/open_url"
git -C "$upstream" show "$rev:crates/rune/src/open_url/instance.rs" > "$work/open_url/instance.rs"
git -C "$upstream" show "$rev:crates/rune/src/quit/relaunch.rs" > "$work/relaunch.rs"
cp "$here/RustPeer.rs" "$work/main.rs"
rustc --edition=2024 -A unused -o "$output" "$@" "$work/main.rs"
