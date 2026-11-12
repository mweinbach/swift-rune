#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MAP_FILE="$REPO_ROOT/.agents/skills/upstream-rune-sync/references/upstream-map.json"

UPSTREAM_DIR=""
EXAMPLE=""
RUST_PNG=""
SWIFT_PNG=""
RUST_TREE=""
SWIFT_TREE=""
SCENE=""
SIZE=""
TOLERANCE="2"
MAX_DIFF_PCT="0.5"
OUT_DIR="/tmp/rune-compare"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Compare visual PNG snapshots (--snap) and layout trees (--tree) between upstream Rust and Swift.

Options:
  --example <name>       Upstream example name (e.g. hello, shapes, glass-card)
  --upstream <dir>       Path to upstream anomalyco/rune clone (runs cargo when available)
  --rust-png <path>      Pre-captured Rust PNG snapshot
  --swift-png <path>     Pre-captured Swift PNG snapshot
  --rust-tree <path>     Pre-captured Rust layout tree JSON
  --swift-tree <path>    Pre-captured Swift layout tree JSON
  --scene <name>         Scene name to pass to --scene
  --size <WxH>           Viewport size (e.g. 1280x800)
  --tolerance <0..255>   Per-channel pixel tolerance (default: 2)
  --max-diff-pct <num>   Max allowed differing pixel percentage (default: 0.5)
  --out-dir <dir>        Output directory for snapshots & diff PNG (default: /tmp/rune-compare)
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --example) EXAMPLE="$2"; shift 2 ;;
    --upstream) UPSTREAM_DIR="$2"; shift 2 ;;
    --rust-png) RUST_PNG="$2"; shift 2 ;;
    --swift-png) SWIFT_PNG="$2"; shift 2 ;;
    --rust-tree) RUST_TREE="$2"; shift 2 ;;
    --swift-tree) SWIFT_TREE="$2"; shift 2 ;;
    --scene) SCENE="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --tolerance) TOLERANCE="$2"; shift 2 ;;
    --max-diff-pct) MAX_DIFF_PCT="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"

SWIFT_PRODUCT=""
if [[ -n "$EXAMPLE" ]]; then
  SWIFT_PRODUCT="$(python3 -c '
import json, sys
umap = json.load(open(sys.argv[1]))
ex = sys.argv[2]
for e in umap.get("examples", []):
    if e["upstreamName"] == ex:
        print(e["swiftProduct"])
        sys.exit(0)
print(f"rune-{ex}")
' "$MAP_FILE" "$EXAMPLE")"
fi

EXTRA_FLAGS=()
[[ -n "$SCENE" ]] && EXTRA_FLAGS+=(--scene "$SCENE")
[[ -n "$SIZE" ]] && EXTRA_FLAGS+=(--size "$SIZE")

if [[ -z "$RUST_PNG" && -n "$EXAMPLE" ]]; then
  RUST_PNG="$OUT_DIR/${EXAMPLE}-rust.png"
  RUST_TREE="${RUST_TREE:-$OUT_DIR/${EXAMPLE}-rust-tree.json}"
  if [[ -n "$UPSTREAM_DIR" ]] && command -v cargo >/dev/null 2>&1; then
    echo "Running upstream Rust example '$EXAMPLE'..."
    cargo run --manifest-path "$UPSTREAM_DIR/Cargo.toml" --example "$EXAMPLE" -- \
      --snap "$RUST_PNG" --tree "$RUST_TREE" "${EXTRA_FLAGS[@]}"
  else
    echo "Note: cargo or --upstream not available; expecting pre-captured --rust-png at $RUST_PNG"
  fi
fi

if [[ -z "$SWIFT_PNG" && -n "$SWIFT_PRODUCT" ]]; then
  SWIFT_PNG="$OUT_DIR/${EXAMPLE}-swift.png"
  SWIFT_TREE="${SWIFT_TREE:-$OUT_DIR/${EXAMPLE}-swift-tree.json}"
  echo "Running Swift product '$SWIFT_PRODUCT'..."
  (cd "$REPO_ROOT" && xcrun swift run "$SWIFT_PRODUCT" --snap "$SWIFT_PNG" --tree "$SWIFT_TREE" "${EXTRA_FLAGS[@]}")
fi

DIFF_PNG="$OUT_DIR/${EXAMPLE:-render}-diff.png"

if grep -q '"rune-parity"' "$REPO_ROOT/Package.swift" 2>/dev/null; then
  CMD=(xcrun swift run rune-parity compare-renders --tolerance "$TOLERANCE" --max-diff-pct "$MAX_DIFF_PCT" --out-diff "$DIFF_PNG")
  [[ -n "$RUST_PNG" ]] && CMD+=(--rust-png "$RUST_PNG")
  [[ -n "$SWIFT_PNG" ]] && CMD+=(--swift-png "$SWIFT_PNG")
  [[ -n "$RUST_TREE" && -f "$RUST_TREE" ]] && CMD+=(--rust-tree "$RUST_TREE")
  [[ -n "$SWIFT_TREE" && -f "$SWIFT_TREE" ]] && CMD+=(--swift-tree "$SWIFT_TREE")
  (cd "$REPO_ROOT" && "${CMD[@]}")
  exit $?
fi

echo "rune-parity CLI not found in Package.swift; using Python fallback comparator..."
python3 - << 'EOF' "$RUST_PNG" "$SWIFT_PNG" "$RUST_TREE" "$SWIFT_TREE" "$TOLERANCE" "$MAX_DIFF_PCT"
import json, math, os, struct, sys, zlib

rust_png, swift_png, rust_tree, swift_tree, tol_s, max_pct_s = sys.argv[1:7]
tol = int(tol_s)
max_pct = float(max_pct_s)

def read_png_rgba(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {path}"
    pos = 8
    w = h = bit_depth = color_type = 0
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos+4])[0]
        ctype = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+length]
        pos += 12 + length
        if ctype == b"IHDR":
            w, h, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break
    bpp = 4 if color_type == 6 else (3 if color_type == 2 else 4)
    raw = zlib.decompress(bytes(idat))
    stride = w * bpp
    out = bytearray(w * h * bpp)
    idx = 0
    for y in range(h):
        filt = raw[idx]; idx += 1
        row = raw[idx:idx+stride]; idx += stride
        prev = out[(y-1)*stride:y*stride] if y > 0 else bytes(stride)
        cur = bytearray(stride)
        for x in range(stride):
            a = cur[x-bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x-bpp] if x >= bpp else 0
            if filt == 0: val = row[x]
            elif filt == 1: val = (row[x] + a) & 0xFF
            elif filt == 2: val = (row[x] + b) & 0xFF
            elif filt == 3: val = (row[x] + ((a + b) >> 1)) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                val = (row[x] + pr) & 0xFF
            else:
                val = row[x]
            cur[x] = val
        out[y*stride:(y+1)*stride] = cur
    return w, h, bpp, out

exit_code = 0
if rust_png and swift_png and os.path.exists(rust_png) and os.path.exists(swift_png):
    rw, rh, rbpp, rbuf = read_png_rgba(rust_png)
    sw, sh, sbpp, sbuf = read_png_rgba(swift_png)
    if (rw, rh) != (sw, sh):
        print(f"FAIL: Dimension mismatch Rust {rw}x{rh} vs Swift {sw}x{sh}")
        sys.exit(1)
    diff_px = 0
    max_delta = 0
    sq_err = 0.0
    total = rw * rh
    for i in range(total):
        ro, so = i * rbpp, i * sbpp
        d = max(abs(rbuf[ro+c] - sbuf[so+c]) for c in range(min(rbpp, sbpp)))
        if d > max_delta: max_delta = d
        if d > tol: diff_px += 1
        for c in range(3):
            e = rbuf[ro+c] - sbuf[so+c]
            sq_err += e * e
    pct = 100.0 * diff_px / max(1, total)
    mse = sq_err / max(1, total * 3)
    psnr = 99.99 if mse == 0 else 10.0 * math.log10((255.0 * 255.0) / mse)
    print(f"Pixel diff: {diff_px}/{total} ({pct:.3f}%), maxDelta={max_delta}, PSNR={psnr:.2f} dB")
    if pct > max_pct:
        exit_code = 1

if rust_tree and swift_tree and os.path.exists(rust_tree) and os.path.exists(swift_tree):
    rt = json.load(open(rust_tree))
    st = json.load(open(swift_tree))
    def count_nodes(n):
        return 1 + sum(count_nodes(c) for c in n.get("children", [])) if isinstance(n, dict) else 0
    rc, sc = count_nodes(rt), count_nodes(st)
    print(f"Layout tree nodes: Rust={rc}, Swift={sc}")
    if rc != sc:
        exit_code = 1

sys.exit(exit_code)
EOF
