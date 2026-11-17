# swift-rune

A Swift 6.4 port of [anomalyco/rune](https://github.com/anomalyco/rune): a cross-platform GPU/CPU-rendered declarative UI framework for **macOS**, **iOS / iPadOS / tvOS / visionOS**, **Windows**, **Linux**, **Android**, and **WebAssembly (`wasm32-unknown-wasip1`)**, with its own layout engine, analytic spring & scene animation runtime, glyph atlas, CPU reference rasterizer, and component kit.

Every `RuneApp` supports headless execution (`--snap`, `--tree`, `--script`, `--frames`, `--strip`) so UIs and automated tests can render PNGs, inspect the element tree, and drive scripted input without a window.

## Architecture & Upstream Mapping

`swift-rune` is organized as a SwiftPM workspace mirroring the crates of upstream `anomalyco/rune`:

| SwiftPM Target | Product | Upstream Crate | Responsibility |
| :--- | :--- | :--- | :--- |
| `RuneMotion` | `RuneMotion` | `crates/rune-motion` | Analytic `Spring(duration:bounce:)`, `Easing` / `CubicBezier`, `Decay`, `KeyframeTrack`, `AnimationStore` (velocity-preserving retargeting, merge/additive blending, premultiplied OKLab color interpolation), `Scene` (4-edge layout morphing, `Transition` enter/exit presence, `reducedMotion`), `Choreography`, `PhaseAnimator`, `Stagger`, `Sequence`/`Beat`, `Cycle`/`LoopTrack`, `VelocityTracker` / rubber-band gestures, `Animated`, `MotionTrace`, and `Clock`. |
| `RuneRef` | `RuneRef` | `crates/rune-ref` | CPU reference rasterizer (`RuneRef.render`) implementing the exact uber-shader primitive set (`Primitive`, `RefScene`, `R8Atlas`, `RGBA8Atlas`), `Frame` PNG encode/decode, pixel-level `RuneRef.diff` (`Difference`, `PixelBlame`), and `rune-ref` CLI (`generate`, `check` GPU-vs-CPU differential parity). |
| `RuneI18n` | `RuneI18n` | `crates/rune-i18n` | BCP-47 `LocaleInfo` parsing, RTL detection, script-aware `negotiateLocale`, system locale detection, CLDR `PluralCategory` rules, number/list formatting, `Template` (`{{name}}` interpolation), JSON `Catalog.fromJSON`, and `I18n` runtime lookup. |
| `RuneTaffy` | `RuneTaffy` | `crates/rune-taffy` | Standalone CSS Flexbox, CSS Grid, Block, and Absolute layout engine (`LayoutEngine`, `TaffyStyle`, `MeasureFunc`, `LayoutCache`, dirty propagation, `roundLayout`). |
| `Rune` | `Rune` | `crates/rune` | Declarative `El<State>` view tree (`row`, `col`, `el`, `text`, `liveText`, `rich`, `icon`, `image`, `canvas`, `textInput`), `Tok` / `JsonTheme` OKLCH design tokens, `LayoutEngine` (flexbox, CSS Grid, block, virtualized growth stacks), `TextEdit` Unicode grapheme editor & `Keybind`, `Shape` / `VectorPath` ear-clipped polygons & strokes, `Live<T>` / `Binding<T>` / `Tween<T>`, `Machine` (`Attempt`, `Seq`, `Effects`), `MetalRenderer` (Apple GPU) & portable CPU raster fallback, cross-platform `RuneApp` shells (`MacOSApp`, `IOSApp`, `Win32Platform`, `LinuxPlatform`, `AndroidPlatform`, `WebPlatform`, `PlatformCommon`), accessibility bridge, rich clipboard, file dialogs, spellcheck, and `HeadlessRunner`. |
| `RuneKit` | `RuneKit` | `crates/rune-kit` | Themable component library built on `Kit.fromPalette(PaletteSeed)` with WCAG contrast enforcement: `button`, `iconButton`, `switchControl`, `checkbox`, `radioGroup`, `segmentedControl`, `slider`, `textInputField`, `textArea`, `field`, `badge`, `divider`, `card`, `progress`, `progressCircle`, `collapsible`, `accordion`, `combobox`, `select`, `dialog`, `toast` / `ToastStack`, `Tooltip`, `Popover`, `HoverCard`, `ContextMenu` / `Menu`, `PopupList`, `RollingText`, `ScrollBar`, `Search`, `ShortcutRecorder`, `ImageZoom`, `Shell` (`Sidebar`, `TabStrip`, `WindowTitlebar`, `PaneState`, `splitView`, `toolbar`), `tree`, `table`, streaming `MarkdownParser` / `markdown`, `Kit.syntax` (`RuneHighlights`), `Kit.mermaid` (`RuneMermaid`), and `FileDiff` / `diffView`. |
| `RuneNotify` | `RuneNotify` | `crates/rune-notify` | System notifications (`UNUserNotificationCenter` on macOS) with deterministic headless/mock backend for tests. |
| `RuneMac` | `RuneMac` | `crates/rune-mac` | macOS `NSWindow` frame persistence/autosave, multi-display clamping, fullscreen, relaunch, and notification helpers. |
| `RunePerf` | `RunePerf` | `crates/rune-perf` + `crates/procwatch` | Bounded local performance recording, Darwin `mach_task_basic_info` CPU/RSS telemetry, scoped spans/histograms, incident persistence, and Chrome Trace Event JSON export. |
| `RuneHighlights` | `RuneHighlights` | `crates/rune-highlights` | Zero-dependency multi-language syntax highlighter supporting 100+ languages with filename, shebang, and content detection. |
| `RuneFX` | `RuneFX` | `crates/rune-fx` | Special-effects layers, catalog/presets, `FireSim` ping-pong planner, `MaskPyramid`, and full Metal Shading Language (MSL) shader suite (glow/bloom, pulses, electricity, procedural fire/embers, motion blur, distortion/ripple, chromatic aberration, vignette/grain). |
| `RuneLight` | `RuneLight` | `crates/rune-light` | Real-time 2D/2.5D lighting and full MSL shader suite (SDF soft shadows, bevel normals, point/directional/spot lights, god rays, radiance-cascade GI, glass refraction). |
| `RuneKnobs` | `RuneKnobs` | `crates/rune-knobs` | Live tuning values (`KnobGroup`, `KnobRegistry`) and `⌘⇧K` tuning panel. |
| `RuneMermaid` | `RuneMermaid` | `crates/rune-mermaid` | Native Mermaid diagram parser, Sugiyama layout, connector routing, and renderer supporting 17 diagram families (flowchart, sequence, state, class, ER, pie, gantt, timeline, journey, gitGraph, mindmap, quadrant, xychart, sankey, block, C4, requirement) with 48 vector shapes. |
| `RuneLuau` | `RuneLuau` | `crates/rune-luau` | Pure-Swift Luau lexer, parser, compiler, sandboxed bytecode VM, execution watchdog, `prelude.luau`, and `@rune/signal` / `@rune/ui` reactive bindings. |
| `RuneRegister` | `RuneRegister` | `crates/rune-register` | Thread-safe distributed item registry (`DistributedRegistry`, `RegistryPart`, `RuneRegister.collect`, `RuneRegister.merge`) for decentralized scene, story, and knob registration. |
| `OpenCodeTheme` | `OpenCodeTheme` | `themes/opencode` | OpenCode theme data, SVG icon sets, and styled components built on `Rune` and `RuneKit`. |

### Example & CLI Executables

| Executable | Target | Upstream Example | Description |
| :--- | :--- | :--- | :--- |
| `rune-hello` | `RuneHello` | `examples/hello` | Minimal interactive card with an animated toggle switch (`on` / `off` scenes). |
| `rune-todo` | `RuneTodo` | `examples/todo` | Scrollable animated task list with `TextEdit` input, progress bar, filter pills, and enter/exit transitions. |
| `rune-settings` | `RuneSettings` | `examples/settings` | Appearance, accent color, font scale, motion, and editor settings panel built with `RuneKit`. |
| `rune-ref` | `RuneRefCLI` | `crates/rune-ref` (`main.rs`) | CLI tool to list/generate CPU reference PNGs and run `check` GPU-vs-CPU differential parity checks. |
| `rune-parity` | `RuneParityCLI` | — | Upstream Rust-vs-Swift differential & sync parity CLI (`status`, `diff-commits`, `compare-renders`, `record-sync`). |
| `rune-shapes` | `RuneShapes` | `examples/shapes` | Vector `Shape` / `VectorPath` ear-clipped polygons, Bézier flattening, and strokes. |
| `rune-glass-card` | `RuneGlassCard` | `examples/glass-card` | Frosted backdrop-blur glass card showcase. |
| `rune-launcher` | `RuneLauncher` | `examples/launcher` | Keyboard-driven command launcher. |
| `rune-playground` | `RunePlayground` | `examples/playground` | Interactive `Rune` + `RuneKit` playground. |
| `rune-kit-gallery` | `RuneKitGallery` | `examples/kit-gallery` | Component gallery for `RuneKit` and `OpenCodeTheme`. |
| `rune-motion-bento` | `RuneMotionBento` | `examples/motion-bento` | `RuneMotion` springs, choreography, transitions, and 4-edge layout morphing showcase. |
| `rune-background` | `RuneBackground` | `examples/background` | Animated procedural background shader & lighting showcase. |
| `rune-cursed-settings` | `RuneCursedSettings` | `examples/cursed-settings` | Stylized settings panel with `RuneFX`, `RuneLight`, and `OpenCodeTheme`. |
| `rune-drag-out` | `RuneDragOut` | `examples/drag-out` | Outbound drag-and-drop file/payload source demo. |
| `rune-drop-files` | `RuneDropFiles` | `examples/drop-files` | Inbound drag-and-drop file target demo. |
| `rune-frosted-bar` | `RuneFrostedBar` | `examples/frosted-bar` | Vibrancy / frosted-glass navigation bar demo. |
| `rune-glass-panel` | `RuneGlassPanel` | `examples/glass-panel` | Refractive glass panel powered by `RuneLight`. |
| `rune-knobs` | `RuneKnobsDemo` | `examples/knobs` | Live tuning panel and `RuneKnobs` interactive controls demo. |
| `rune-lab` | `RuneLab` | `examples/lab` | Shader, lighting, and motion experimentation lab. |
| `rune-live-values` | `RuneLiveValues` | `examples/live-values` | Reactive `Live<T>` / `Binding<T>` value inspector demo. |
| `rune-luau-panel` | `RuneLuauPanel` | `examples/luau-panel` | Live-evaluated `RuneLuau` scriptable UI panel. |
| `rune-matched` | `RuneMatched` | `examples/matched` | Matched-geometry `RuneMotion` layout transition showcase. |
| `rune-odometer` | `RuneOdometer` | `examples/odometer` | Animated rolling-digit odometer counter demo. |
| `rune-overlay` | `RuneOverlay` | `examples/overlay` | Transparent floating overlay window demo. |
| `rune-overlay-lab` | `RuneOverlayLab` | `examples/overlay-lab` | Multi-layer overlay positioning and hit-testing lab. |
| `rune-rich-clipboard` | `RuneRichClipboard` | `examples/rich-clipboard` | Rich text, HTML, and image clipboard read/write demo. |
| `rune-showreel` | `RuneShowreel` | `examples/showreel` | Multi-scene showcase combining `RuneMotion`, `RuneFX`, `RuneLight`, and `RuneMermaid`. |
| `rune-site-scenes` | `RuneSiteScenes` | `examples/site-scenes` | Headless material stills renderer (liquid metal, glass, and light). |
| `rune-sketch` | `RuneSketch` | `examples/sketch` | Freehand vector path sketching canvas demo. |
| `rune-video-player` | `RuneVideoPlayer` | `examples/video-player` | Native video playback and transport controls demo. |
| `rune-video-tiles` | `RuneVideoTiles` | `examples/video-tiles` | Multi-stream synchronized video tile grid demo. |
| `rune-web-hello` | `RuneWebHello` | `examples/web-hello` | Minimal web/DOM export target example. |
| `rune-web-showcase` | `RuneWebShowcase` | `examples/web-showcase` | Interactive `RuneKit` + `RuneMotion` web export showcase. |

## Quick Start

```swift
import Rune

struct HelloState {
    var on: Bool = false
}

func helloView(_ s: HelloState, _ cx: inout Cx<HelloState>) -> El<HelloState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)

    return col()
        .sizeFull()
        .center()
        .gap(16)
        .bg(t.bg)
        .child(text(s.on ? "Lights on" : "Lights off").size(18).semibold().color(t.text))
        .child(
            el()
                .key("sw")
                .role(.switchControl)
                .size(40, 22)
                .pill()
                .bg(s.on ? accent : t.controlOff)
                .animate(Tok.Motion.SNAPPY)
                .onClick { $0.on.toggle() }
                .child(
                    el()
                        .key("knob")
                        .square(18)
                        .pill()
                        .bg(t.knob)
                        .absolute(x: s.on ? 20 : 2, y: 2)
                        .animateLayout(Tok.Motion.SNAPPY)
                )
        )
}

let spec = AppSpec<HelloState>(
    title: "Hello Rune",
    size: Vec2(460, 300),
    state: HelloState(),
    view: helloView
)
.scene("on") { $0.on = true }

try RuneApp.run(spec)
```

Using `RuneKit`:

```swift
import Rune
import RuneKit

let kit = Kit.fromPalette(
    PaletteSeed(
        bg: Color.hex("#111318")!,
        fg: Color.hex("#f1f3f5")!,
        accent: Tok.accent(0, dark: true)
    ),
    focus: .accent
)

let card = kit.card(
    key: "panel",
    col().gap(12)
        .child(text("Settings").font(kit.ty.uiMedium).color(kit.c.textBase))
        .child(kit.divider())
        .child(kit.switchControl(key: "toggle", on: true) { _ in })
)
```

## Build & Test

Requires **Swift 6.4+** (`// swift-tools-version: 6.4`, `swiftLanguageModes: [.v6]`). On macOS setups where `swiftly` is ahead of Xcode in `PATH`, use `xcrun swift` so the Xcode SDK and toolchain match:

```bash
# Run all 18 test targets
xcrun swift test

# Build all 17 libraries, 33 executables, and 18 test targets
xcrun swift build

# Run any interactive example or CLI tool
xcrun swift run rune-hello
xcrun swift run rune-todo
xcrun swift run rune-settings
xcrun swift run rune-shapes
xcrun swift run rune-glass-card
xcrun swift run rune-launcher
xcrun swift run rune-playground
xcrun swift run rune-kit-gallery
xcrun swift run rune-motion-bento
xcrun swift run rune-ref check
```

### Cross-Platform Architecture & Builds

`Package.swift` configures Apple deployment minimums (`.macOS(.v14)`, `.iOS(.v17)`, `.tvOS(.v17)`, `.visionOS(.v1)`) and conditional system libraries for Windows and Android. Linux and WebAssembly (`wasm32-unknown-wasip1`) use portable host implementations.

| Platform | Backend / Shell (`Sources/Rune/`) | Build Command |
| :--- | :--- | :--- |
| **macOS** (14+) | `MacOSApp.swift` (`AppKit` / `MTKView` / `CoreText` / `Metal`) | `xcrun swift build` |
| **iOS / iPadOS / tvOS / visionOS** (iOS 17+, tvOS 17+, visionOS 1+) | `IOSApp.swift` (`UIKit` / `CADisplayLink` / `Metal`) | `xcrun swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios17.0-simulator --target RuneKit` |
| **Windows** (Win32 + DWM) | `Win32Platform.swift` (`user32`, `gdi32`, `dwmapi`, `ole32`, `shell32`, `psapi`) | `swift build` (Windows Swift 6.4 toolchain) |
| **Linux** (Wayland / `wlr-layer-shell` / X11 / XDG Portal) | `LinuxPlatform.swift` (`Glibc` / `Musl`, Wayland layer-shell state machine, X11, XDG Portal appearance) | `swift build` (Linux Swift 6.4 toolchain) |
| **Android** (NDK / `ANativeWindow` / `Choreographer`) | `AndroidPlatform.swift` (`Android` NDK, `android`, `log`) | `swift build --swift-sdk <android-sdk>` |
| **WebAssembly** (`wasm32-unknown-wasip1`) | `WebPlatform.swift` (`WASILibc`, DOM / CPU canvas bridge, `web_math`) | `swift build --swift-sdk <wasip1-sdk>` |

`mountRuneFields(canvas, send)` in `Sources/Rune/Resources/Web/rune-web.mjs` mounts a native textarea and password field beside an existing canvas. Pass Rune’s `WebAppHost.onFieldChange` updates to its `sync(field, activate)` method and route its edit, selection and secure insert events to the corresponding `WebAppHost` handlers. Call `dispose()` when the canvas unmounts.

The standalone WASI browser entry uses a Preview 1 reactor. Building the full package for WASI currently requires resolving existing portability issues in RuneRef and Rune, including Apple-only imports. The build command for a toolchain with a matching Swift SDK is:

```bash
./scripts/build-web.sh <wasip1-sdk> rune-web-hello
```

Serve the resulting `.wasm` file and the module in `Sources/Rune/Resources/Web/rune-web.mjs`. Instantiate the reactor with the page’s WASI Preview 1 implementation and initialize it once before mounting it on a canvas. For example, with a WASI host that exposes `wasiImport` and `initialize`:

```js
import { mountRuneBrowser } from './rune-web.mjs';

const { instance } = await WebAssembly.instantiateStreaming(fetch('./rune-web-hello.wasm'), {
    wasi_snapshot_preview1: wasi.wasiImport
});
wasi.initialize(instance);
const app = mountRuneBrowser(document.querySelector('canvas'), instance);
// Call app.dispose() when the page removes the canvas.
```

The browser adapter draws CPU frames into the canvas and gives the focused Rune editor a native textarea or password input for keyboard and assistive input.

### Headless Rendering & Inspection

Any `RuneApp` executable accepts headless tooling flags (parsed by `ToolingArgs`):

```bash
# List available named scenes
xcrun swift run rune-hello --list-scenes

# Render a PNG snapshot of a named scene
xcrun swift run rune-hello --snap /tmp/hello-on.png --scene on --dark

# Dump the laid-out element tree to JSON
xcrun swift run rune-hello --tree /tmp/hello-tree.json

# Drive scripted input (JSON file or inline JSON) and capture frames
xcrun swift run rune-todo --script script.json --frames /tmp/frames --fps 60
```

Supported flags: `--snap <path>`, `--tree <path>`, `--scene <name>`, `--list-scenes`, `--script <json|path>`, `--frames <dir>`, `--strip <path>`, `--fps <n>`, `--scale <n>`, `--time-scale <n>`, `--duration <sec>`, `--at <sec>`, `--start <sec>`, `--crop <x,y,w,h>`, `--every <n>`, `--theme <name>`, `--size <WxH>`, `--dark` / `--light`, `--reduced-motion`, `--cpu` (force CPU `RuneRef` instead of Metal).

## Upstream Parity & Sync Workflow (`rune-parity` & `.agents/skills/upstream-rune-sync`)

`swift-rune` tracks upstream `anomalyco/rune` parity using the `.upstream-sync.json` state file, the `.agents/skills/upstream-rune-sync` skill (with `references/upstream-map.json`), and the `rune-parity` CLI (`Sources/Examples/RuneParityCLI`, 33 executables total, 18 test targets):

```bash
# 1. Verify every upstream crate, .rs/.wgsl file, theme, and example is mapped and present in Swift
xcrun swift run rune-parity status --upstream /path/to/rune

# 2. Inspect upstream git commits since .upstream-sync.json and generate a Swift porting plan
xcrun swift run rune-parity diff-commits --upstream /path/to/rune

# 3. Run differential Rust-vs-Swift PNG & layout-tree comparison for an example
xcrun swift run rune-parity compare-renders --upstream /path/to/rune --example hello --scene on --out-diff /tmp/hello-diff.png

# Or compare pre-captured PNGs and --tree JSON dumps directly
xcrun swift run rune-parity compare-renders --rust-png /tmp/rust.png --swift-png /tmp/swift.png --rust-tree /tmp/rust-tree.json --swift-tree /tmp/swift-tree.json --out-diff /tmp/diff.png

# 4. Record the newly synced upstream HEAD commit into .upstream-sync.json
xcrun swift run rune-parity record-sync --upstream /path/to/rune
```

All `rune-parity` subcommands support `--json` for machine-readable output and exit non-zero on unmapped files, missing Swift paths, or visual/layout regressions.

## License

MIT — see [LICENSE](LICENSE).
