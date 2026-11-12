---
name: upstream-rune-sync
description: >-
  Compares swift-rune against upstream Rust anomalyco/rune, audits commit and
  symbol deltas, and ports new Rust crates, WGSL-to-Metal shaders, and examples
  to Swift 6. Use this skill whenever the user asks to compare against upstream
  anomalyco/rune, check for upstream updates, audit parity, or port new Rust
  features, commits, shaders, or examples to Swift.
---

# Upstream Rune Sync

Workflow for keeping `swift-rune` synchronized with [`anomalyco/rune`](https://github.com/anomalyco/rune) using `.upstream-sync.json`, the machine-readable [upstream-map.json](./references/upstream-map.json), and the [rust-to-swift-playbook.md](./references/rust-to-swift-playbook.md).

## Prerequisites

- Always use **`xcrun swift build`** and **`xcrun swift test`** (never bare `swift`).
- Baseline state is tracked in `.upstream-sync.json` at the repository root.

---

## Workflow

### 1. Fetch & Delta Audit

Fetch upstream `anomalyco/rune` (into `${UPSTREAM_DIR:-/tmp/anomalyco-rune}`, or pass `--upstream <dir>` for an existing local clone) and compare `HEAD` against `.upstream-sync.json`:

```bash
./.agents/skills/upstream-rune-sync/scripts/fetch_upstream.sh
# Or offline/local clone:
./.agents/skills/upstream-rune-sync/scripts/fetch_upstream.sh --upstream /path/to/rune
```

Run the zero-dependency delta auditor to detect unmapped files/crates/examples and extract changed Rust `pub` symbols and WGSL shader entrypoints:

```bash
./.agents/skills/upstream-rune-sync/scripts/audit_upstream_delta.py \
  --upstream "${UPSTREAM_DIR:-/tmp/anomalyco-rune}" \
  --symbols
```

If `rune-parity` is built, you can also run `xcrun swift run rune-parity status --upstream <dir>` and `xcrun swift run rune-parity diff-commits --upstream <dir>`.

### 2. Map & Plan

- Cross-reference every changed upstream file in the audit output against [upstream-map.json](./references/upstream-map.json).
- If upstream added a new crate, `.rs`/`.wgsl` module, or `examples/*` target, add its mapping to [upstream-map.json](./references/upstream-map.json) and wire the Swift target/product in `Package.swift`.
- **Multi-crate releases (`/swarm`)**: When syncing a large upstream release spanning multiple independent crates (e.g., `rune-fx`, `rune-light`, `rune-motion`, `rune-kit`), use `/swarm` to parallelize porting by Swift target—assigning each worker its own `Sources/<Target>/` + `Tests/<Target>Tests/` slice and running a dedicated verifier after integration.

### 3. Port Following Playbook

Read [rust-to-swift-playbook.md](./references/rust-to-swift-playbook.md) before writing code. Key rules:

- **Swift 6.4 Concurrency**: `Package.swift` targets `// swift-tools-version: 6.4` (`swiftLanguageModes: [.v6]`). Value types must be `Sendable`; shared mutable stores use locks (`@unchecked Sendable`) or `actor` isolation.
- **Cross-Platform Portability**: Never use unguarded `import Darwin`, `simd`, `Metal`, `CoreGraphics`, `CoreText`, `ImageIO`, `AppKit`, `UIKit`, or `AVFoundation`. Guard C stdlib imports (`Darwin`/`Glibc`/`Musl`/`Android`/`WinSDK`/`WASILibc`), guard `Foundation.Process` for iOS/WASI (`#if os(macOS) || os(Linux) || os(Windows)`), and provide headless/CPU fallbacks so `xcrun swift test` passes without a GUI session.
- **WGSL -> Metal**: Translate `.wgsl` shaders to MSL string literals compiled via `MTLDevice.makeLibrary(source:)`. Watch `simd_float3` 16-byte alignment, add explicit padding fields, and assert `MemoryLayout<Uniforms>.stride` in unit tests.
- **iOS Simulator Verification**: Verify library targets compile for iOS Simulator via:
  ```bash
  xcrun swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios17.0-simulator
  ```

### 4. Differential Rust-vs-Swift & Unit Test Verification

Run unit tests for every touched Swift target (plus dependent targets):

```bash
xcrun swift test --filter <TestTarget>
```

For visual examples and shader changes, run differential PNG + layout-tree comparison against upstream Rust using [compare_rust_vs_swift.sh](./scripts/compare_rust_vs_swift.sh):

```bash
./.agents/skills/upstream-rune-sync/scripts/compare_rust_vs_swift.sh \
  --example hello \
  --upstream "${UPSTREAM_DIR:-/tmp/anomalyco-rune}" \
  --tolerance 2 \
  --max-diff-pct 0.5
```

Verify zero regressions in pixel PSNR/diff percentage and layout-tree node counts/bounding boxes.

### 5. Record Synced Commit

Once all tests and differential checks pass, update `.upstream-sync.json` to the new upstream `HEAD`:

```bash
xcrun swift run rune-parity record-sync --upstream "${UPSTREAM_DIR:-/tmp/anomalyco-rune}"
```
