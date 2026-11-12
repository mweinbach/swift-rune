# Rust-to-Swift Translation Playbook (`anomalyco/rune` -> `swift-rune`)

Authoritative guide for translating upstream Rust crates, WGSL shaders, and examples from [`anomalyco/rune`](https://github.com/anomalyco/rune) into Swift 6 (`swift-rune`).

---

## 1. Toolchain, Swift 6.4 Concurrency & Cross-Platform Portability Rules

- **Always invoke the Xcode toolchain via `xcrun`**:
  - `Package.swift` uses `// swift-tools-version: 6.4` with `swiftLanguageModes: [.v6]`.
  - Use `xcrun swift build` and `xcrun swift test` (NEVER bare `swift`, which can pick up an older CommandLineTools SDK missing Metal/AppKit/Swift 6.4 headers).
  - When building from a background agent or isolated scratch path, pass `--scratch-path <dir>` to avoid lock contention on `.build/`.
  - Verify iOS Simulator builds for all library targets via:
    ```bash
    xcrun swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios17.0-simulator
    ```
- **Cross-Platform Portability (`macOS`, `iOS`, `tvOS`, `visionOS`, `Windows`, `Linux`, `Android`, `WASI`)**:
  - **Never use unguarded Apple/OS imports**: never write bare `import Darwin`, `import simd`, `import Metal`, `import MetalKit`, `import CoreGraphics`, `import CoreText`, `import ImageIO`, `import AppKit`, `import UIKit`, `import AVFoundation`, `import UserNotifications`, `import QuartzCore`, or `import UniformTypeIdentifiers`. Always wrap them in `#if canImport(...)` / `#if os(...)` and provide portable fallbacks.
  - **C standard library imports**: replace bare `import Darwin` with conditional `#if canImport(Darwin) ... #elseif canImport(Glibc) ... #elseif canImport(Musl) ... #elseif canImport(Android) ... #elseif canImport(WinSDK) ... #elseif canImport(WASILibc) ... #endif`.
  - **Subprocess spawning (`Foundation.Process`)**: `Process` is unavailable on iOS, tvOS, visionOS, and WASI. Always guard `Foundation.Process` usage with `#if os(macOS) || os(Linux) || os(Windows)`.
  - **PNG & Rasterization**: use pure-Swift `PortablePNG` / `RuneRef.Frame` instead of `ImageIO` / `CoreGraphics` for cross-platform PNG encode/decode.
- **Swift 6 Strict Concurrency (`Sendable`)**:
  - Value types (`struct`, `enum`) crossing task or renderer boundaries must conform to `Sendable` (and `Equatable` / `Hashable` where used in memoization or diffing).
  - Mutable runtime stores (`AnimationStore`, `LayoutCache`, `PerfIncidentStore`, `KnobRegistry`) use `final class ...: @unchecked Sendable` guarded by `NSLock` / `os_unfair_lock`, or `actor` isolation when async.
  - Prefer `sending` / value semantics for `El` trees and frame snapshots; avoid global mutable `var`s without `@MainActor` or lock protection.

---

## 2. `wgpu` + `.wgsl` Shaders -> Metal (`MTLDevice.makeLibrary(source:)`)

Upstream crates `rune`, `rune-fx`, and `rune-light` compile `.wgsl` shaders for `wgpu`. In `swift-rune`, shaders are embedded as Swift string literals (`RuneFXShaders.swift`, `RuneLightShaders.swift`, `MetalRenderer.swift`) and compiled at runtime via `MTLDevice.makeLibrary(source:options:)`.

### WGSL -> MSL Translation Checklist

| WGSL Construct | Metal Shading Language (MSL) Equivalent | Notes |
|---|---|---|
| `@vertex fn vs_main(...)` | `vertex VertexOut vs_main(...)` | Use `[[stage_in]]` or `uint vid [[vertex_id]]` |
| `@fragment fn fs_main(...)` | `fragment float4 fs_main(...)` | Return `float4` (or struct with `[[color(0)]]`) |
| `@compute @workgroup_size(8, 8)` | `kernel void cs_main(...)` | Bind `uint2 gid [[thread_position_in_grid]]` |
| `var<uniform> u: Uniforms` | `constant Uniforms& u [[buffer(N)]]` | Read-only uniform address space |
| `var<storage, read> buf: array<T>` | `device const T* buf [[buffer(N)]]` | Read-only storage buffer |
| `var<storage, read_write> buf: array<T>` | `device T* buf [[buffer(N)]]` | Read-write storage buffer |
| `var<private>` / local | `thread` (default in function scope) | Explicit `thread` when passing pointers |
| `texture_2d<f32>` + `sampler` | `texture2d<float> tex [[texture(N)]]`, `sampler samp [[sampler(N)]]` | Use `tex.sample(samp, uv)` or `tex.read(uint2(...))` |
| `texture_storage_2d<rgba16float, write>` | `texture2d<float, access::write> out [[texture(N)]]` | Use `out.write(val, gid)` |
| `vec2<f32>`, `vec3<f32>`, `vec4<f32>` | `float2`, `float3`, `float4` | |
| `mat4x4<f32>` | `float4x4` | Column-major in both WGSL and MSL |
| `select(falseVal, trueVal, cond)` | `select(falseVal, trueVal, cond)` | Same argument order in MSL |
| `mix(a, b, t)`, `clamp`, `smoothstep` | `mix(a, b, t)`, `clamp`, `smoothstep` | Built-in in `<metal_stdlib>` |

### Alignment & Padding Traps (`simd_float*`)

1. **`simd_float3` is 16-byte aligned and 16 bytes in size** in both Swift `<simd/simd.h>` and Metal `float3` (`packed_float3` is 12 bytes, avoid in uniform structs). Never assume a `float3` packs in 12 bytes.
2. **Match WGSL `std140` / `std430` layout explicitly**:
   - Align `float4` / `simd_float4` to 16 bytes.
   - Align `float2` / `simd_float2` to 8 bytes.
   - Insert explicit `var _pad0: Float = 0` / `float _pad0;` fields in both Swift and MSL structs rather than relying on implicit compiler padding.
3. **Assert uniform byte sizes in tests**:
   - Every GPU uniform struct should have a unit test asserting `MemoryLayout<MyUniforms>.stride == <expected_bytes>` (16-byte aligned for Metal constant buffers).
4. **CPU Differential Validation (`RuneRef`)**:
   - Every shader/effect in `Rune`, `RuneFX`, and `RuneLight` has a CPU reference path (`RuneRef/Shader.swift`, `RuneFXCPU.swift`, `RuneLightCPU.swift`).
   - Validate Metal output against the CPU reference or upstream Rust PNG using `RuneRef` (`Frame.fromPNG`, `RuneRef.diff`, `PixelBlame`).

---

## 3. `crates/rune` -> `Sources/Rune` Architecture Mapping

| Upstream Rust (`crates/rune/src/`) | Swift Target (`Sources/Rune/`) | Key Types & Conventions |
|---|---|---|
| `el/*`, `color.rs`, `theme.rs`, `tok.rs` | `El.swift` | `El<State>` declarative builder, `Tx` transition/transform modifiers, `Color`, `Theme` tokens |
| `el/grid.rs` | `GridLayout.swift` | CSS-grid track sizing (`fr`, `auto`, `px`, `minmax`), spans, alignment |
| `runtime/layout*` | `Layout.swift` | `LayoutEngine` bridging `El` nodes to `RuneTaffy` + `GridLayout` |
| `text/*`, `edit/*`, `shape.rs` | `Text.swift`, `Edit.swift`, `Shape.swift` | CoreText / harfbuzz-parity shaping, `TextInput` state machine, vector paths |
| `machine/*` | `Machine.swift` | Deterministic state machines for interactive widgets |
| `runtime/*`, `frame/*`, `overlay/*`, `input/*` | `Runtime.swift` | Frame tick, hit-testing, focus, overlay stack, isolated `Layer`s |
| `runtime/virtual/*`, `growth/*` | `VirtualList.swift` | Virtualized scrolling & dynamic item measurement |
| `flight.rs`, `memo/*`, `motion_gate/*`, `tracked.rs`, `latest.rs`, `states.rs`, `marks.rs`, `labels.rs`, `compose.rs` | `FlightAndMemo.swift` | Render-tree memoization, motion gating, tracked state keys |
| `gpu/*`, `render/*`, `*.wgsl` | `MetalRenderer.swift` | 13 core primitives, `backdropBlur`, `backdropComposite`, `outlineGlyph`, `evaluateSpringsOnGPU` |
| `app/*`, `window/*`, `platform/*` | `PlatformCommon.swift`, `MacOSApp.swift`, `IOSApp.swift`, `Win32Platform.swift`, `LinuxPlatform.swift`, `AndroidPlatform.swift`, `WebPlatform.swift` | Cross-platform `RuneApp.run(spec)` host shells (`AppKit`/`MTKView` on macOS, `UIKit`/`CADisplayLink` on iOS/tvOS/visionOS, `Win32` + DWM, Linux Wayland/`wlr-layer-shell`/X11/XDG Portal, Android NDK `ANativeWindow`, Web/WASM DOM bridge) |
| `clipboard/*`, `drag_out/*`, `file_dialog/*`, `native_menu/*`, `tray/*`, `open_url/*`, `system_material/*` | `DesktopIntegration.swift` | Guard all AppKit/Cocoa APIs with `#if os(macOS)` and provide headless in-memory/mock fallbacks so `xcrun swift test` passes without a GUI session |
| `video/*`, `image/*` | `MediaPipeline.swift` | `AVFoundation` / `ImageIO` decoding with headless stub support |
| `recorder/*`, `rewind/*` | `RecorderAndRewind.swift` | Frame/input event recording and deterministic replay |
| `playground/*` | `PlaygroundHost.swift` | Live playground scene runner |
| `a11y/*`, `spell/*`, `shortcuts/*`, `input/chord.rs`, `input/keycaps.rs` | `AccessibilityAndInput.swift` | `NSAccessibility` bridge (`#if os(macOS)`), chord parser, keycap formatting |

---

## 4. `crates/rune-motion` -> `Sources/RuneMotion`

- **Analytic Springs (`Spring.swift`)**: Closed-form damped harmonic oscillator (`stiffness`, `damping`, `mass`, underdamped/critically damped/overdamped) so any `t` evaluates in $O(1)$ without numerical drift.
- **Choreography (`Choreography.swift`)**: Staggered, sequenced, and parallel timeline orchestration over `Clock` / `Sequence`.
- **Scene 4-Edge Morphing (`Scene.swift`)**: `Scene`, `Phase`, `Presence`, `Trailing`, `Travel` — interpolates bounding-box 4 edges (`top`, `left`, `bottom`, `right`) independently for shared-element transitions.
- **Snap & Carry (`Snap.swift`)**: `MotionMath`, `Carry` velocity handoff, and snap-point projection.

---

## 5. `crates/rune-luau` -> `Sources/RuneLuau`

- **Pure-Swift Luau VM**: `LuauLexer`, `LuauParser`, `LuauCompiler`, `LuauVM`, `LuauStdlib`, `Watchdog` (instruction/memory budget enforcement) — zero C/C++ FFI dependencies.
- **Task Scheduler & Signals (`TaskScheduler.swift`)**: Implements `prelude.luau` and `@rune/signal` reactive primitives.
- **Host Bindings (`UI.swift`, `Card.swift`, `Script.swift`)**: Exposes `@rune/ui` node builders to Luau scripts and marshals resulting trees into `Rune.El` / `RuneKit` components.

---

## 6. `crates/rune-kit` + Satellite Crates

- **`RuneKit` (`Sources/RuneKit/`)**: High-level UI kit (`Controls`, `InputsAndContainers`, `Components`, `Overlays`, `Markdown`, `Diff`, `Shell`, `FileTree`). Keep `RuneKit` decoupled from `OpenCodeTheme` except through theme token protocols/defaults.
- **`RuneHighlights` (`Sources/RuneHighlights/`)**: Pure-Swift lexers for 81 languages + `plain` (82 total) with `Language.fromFilename` / `fromShebang` / `detect`.
- **`RuneMermaid` (`Sources/RuneMermaid/`)**: 17 diagram families + `MermaidSteady`, `MermaidScenes`, `MermaidChart`, `MermaidDate`.
- **`OpenCodeTheme` (`Sources/OpenCodeTheme/`)**: Theme tokens, color scales, syntax palette, spacing, box shadows, and 6 SVG icon catalogs (`OpenCodeIcons`, `OpenCodeNewIcons`, `OpenCodeAppIcons`, `OpenCodeProviderIcons`, `OpenCodeFileIcons`, `OpenCodeTreeIcons`).
