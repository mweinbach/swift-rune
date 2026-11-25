# swift-rune

[![Swift 6.4+](https://img.shields.io/badge/Swift-6.4%2B-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20iOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Android%20%7C%20Wasm-blue)](#cross-platform-architecture--builds)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A **SwiftPM** cross-platform, GPU-rendered declarative UI framework in Swift 6.4 — a port of [anomalyco/rune](https://github.com/anomalyco/rune) for **macOS**, **iOS / iPadOS / tvOS / visionOS**, **Windows**, **Linux**, **Android**, and **WebAssembly (`wasm32-unknown-wasip1`)**, complete with its own Flexbox/Grid layout engine, analytic spring & scene animation runtime, glyph atlas, CPU reference rasterizer, and WCAG-checked component kit (`RuneKit`).

Every `RuneApp` supports headless execution (`--snap`, `--tree`, `--script`, `--frames`, `--strip`) so UIs and automated tests can render PNGs, inspect the element tree, and drive scripted input without a window.

## Documentation

- [**Getting Started**](docs/getting-started.md) — Add `swift-rune` via SwiftPM, build your first cross-platform UI app, and configure platform prerequisites.
- [**Core UI, Layout & Styling Guide**](docs/ui-guide.md) — Declarative `El<State>` trees, Flexbox & CSS Grid, absolute/sticky positioning, OKLCH colors & tokens, vector `Shape`/`Path`, `ImageCache`, and virtualized scrolling.
- [**State, Events & Architecture**](docs/state-and-architecture.md) — `AppSpec` vs `App`, `AppHandle`, `Cx`/`Tx`, zero-rebuild `Live<T>` bindings, async `Attempt`/`Seq`/`Waker`, keyboard/drag/text input, accessibility, and desktop services (`RuneNotify`, `RuneMac`, `RuneI18n`).
- [**Motion & Animation Guide**](docs/motion-and-animation.md) — Analytic `Spring` physics, OKLab color transitions, 4-edge layout morphing (`.animateLayout`), enter/exit `.transition`, `CubicBezier`, staggers, `Choreography`, and reduced-motion support.
- [**RuneKit Component Guide**](docs/runekit-components.md) — Theming with `Kit.fromPalette`, buttons, form controls, overlays/dialogs/menus/toasts, desktop app shells, virtualized tables & trees, streaming Markdown, syntax highlighting, Mermaid diagrams, and diff views.
- [**Visual Effects, Lighting & Custom GPU**](docs/effects-lighting-and-gpu.md) — Custom native Metal/OpenGL/WebGPU `Compositor` passes, `RuneFX` shader layers & procedural fills, `RuneLight` 2D/2.5D lighting & refractive glass, and `RuneKnobs` live tuning.
- [**Testing, Profiling & Deployment**](docs/testing-and-deployment.md) — Headless CLI snapshots (`--snap`, `--tree`, `--script`), XCTest/Swift Testing with `HeadlessRunner` & `RuneRef.diff`, frame-phase profiling, and deployment checklists for macOS, iOS, Windows, Linux, Android, and WebAssembly.
- [**Products & Modules**](docs/products-and-modules.md) — Full reference for all 18 SwiftPM library products, package traits (`DesktopMedia`), and platform backends.
- [**Standalone App Example**](examples/SparkStudio) — Complete multi-panel SwiftPM desktop app consuming `Rune`, `RuneKit`, and `RuneMotion`.

## Installation (SwiftPM)

Add `swift-rune` to your `Package.swift` dependencies (requires **Swift 6.4+**):

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    dependencies: [
        .package(url: "https://github.com/mweinbach/swift-rune.git", from: "0.1.0"),
        // Or track the latest commits on main:
        // .package(url: "https://github.com/mweinbach/swift-rune.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "Rune", package: "swift-rune"),
                .product(name: "RuneKit", package: "swift-rune"),
                // Optional add-on libraries:
                // .product(name: "RuneFX", package: "swift-rune"),
                // .product(name: "RuneLight", package: "swift-rune"),
                // .product(name: "RuneNotify", package: "swift-rune"),
                // .product(name: "OpenCodeTheme", package: "swift-rune"),
            ]
        ),
    ]
)
```

> **Tip:** `Rune` re-exports `RuneMotion` and `RuneRef`. For UI-only builds on Linux/Windows without desktop audio/video playback, pass `traits: []` on the `swift-rune` dependency in your `Package.swift` (or `--disable-default-traits` when building inside this checkout) to disable the default `DesktopMedia` trait.

## Quick Start

Put the following in `Sources/MyApp/main.swift` (or use `@main` in any Swift file) to launch a cross-platform animated UI window:

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
                .label("Lights")
                .selected(s.on ? "true" : "false")
                .focusable(true)
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

To build rich themed interfaces with `RuneKit` controls (cards, buttons, inputs, dialogs, tables, trees, markdown, and app shells):

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

func settingsView(_ state: HelloState, _ cx: inout Cx<HelloState>) -> El<HelloState> {
    col()
        .sizeFull()
        .center()
        .bg(kit.c.page)
        .child(
            kit.card(
                key: "panel",
                col()
                    .w(300)
                    .gap(12)
                    .child(text("Settings").font(kit.ty.uiMedium).color(kit.c.textBase))
                    .child(kit.divider())
                    .child(
                        kit.switchControl(key: "toggle", isOn: state.on, label: "Lights") { state, isOn in
                            state.on = isOn
                        }
                    )
            )
        )
}
```

### Large-View Benchmarks

To measure scrolling on your machine, run `swift run --package-path Tests/Support/LargeViews -c release ScrollBench table window` for the 100,000-row table. Use `tree` for the 50,000-file tree or `diff` for the 50,000-line code diff. Each workload sends 600 wheel events and verifies the visible rows. On macOS, add `--metal-presents .build/scroll/frames.csv` to record when each frame appeared on screen. [Large-view benchmark and Rust comparison](Tests/Support/LargeViews/README.md)

## Architecture & Upstream Mapping

`swift-rune` is organized as a SwiftPM workspace mirroring the crates of upstream `anomalyco/rune`:

| SwiftPM Target | Product | Upstream Crate | Responsibility |
| :--- | :--- | :--- | :--- |
| `RuneMotion` | `RuneMotion` | `crates/rune-motion` | Analytic `Spring(duration:bounce:)`, `Easing` / `CubicBezier`, `Decay`, `KeyframeTrack`, `AnimationStore` (velocity-preserving retargeting, merge/additive blending, premultiplied OKLab color interpolation), `Scene` (4-edge layout morphing, `Transition` enter/exit presence, `reducedMotion`), `Choreography`, `PhaseAnimator`, `Stagger`, `Sequence`/`Beat`, `Cycle`/`LoopTrack`, `VelocityTracker` / rubber-band gestures, `Animated`, `MotionTrace`, and `Clock`. |
| `RuneRef` | `RuneRef` | `crates/rune-ref` | CPU reference rasterizer (`RuneRef.render`) implementing the exact uber-shader primitive set (`Primitive`, `RefScene`, `R8Atlas`, `RGBA8Atlas`), `Frame` PNG encode/decode, pixel-level `RuneRef.diff` (`Difference`, `PixelBlame`), and `rune-ref` CLI (`generate`, `check` GPU-vs-CPU differential parity). |
| `RuneI18n` | `RuneI18n` | `crates/rune-i18n` | BCP-47 `LocaleInfo` parsing, RTL detection, script-aware `negotiateLocale`, system locale detection, CLDR `PluralCategory` rules, number/list formatting, `Template` (`{{name}}` interpolation), JSON `Catalog.fromJSON`, and `I18n` runtime lookup. |
| `RuneTaffy` | `RuneTaffy` | `crates/rune-taffy` | Standalone CSS Flexbox, CSS Grid, Block, and Absolute layout engine (`LayoutEngine`, `TaffyStyle`, `MeasureFunc`, `LayoutCache`, dirty propagation, `roundLayout`). |
| `Rune` | `Rune` | `crates/rune` | Declarative `El<State>` view tree (`row`, `col`, `el`, `text`, `liveText`, `rich`, `icon`, `image`, `canvas`, `textInput`), `Tok` / `JsonTheme` OKLCH design tokens, `LayoutEngine` (flexbox, CSS Grid, block, virtualized growth stacks), `TextEdit` Unicode grapheme editor & `Keybind`, `Shape` / `VectorPath` ear-clipped polygons & strokes, `Live<T>` / `Binding<T>` / `Tween<T>`, `Machine` (`Attempt`, `Seq`, `Effects`), Metal, OpenGL, OpenGL ES, WebGPU and WebGL 2 rendering, a portable CPU reference renderer, and native and browser app hosts, accessibility bridge, rich clipboard, file dialogs, spellcheck, and `HeadlessRunner`. |
| `RuneKit` | `RuneKit` | `crates/rune-kit` | Themable component library built on `Kit.fromPalette(PaletteSeed)` with WCAG contrast enforcement: `button`, `iconButton`, `switchControl`, `checkbox`, `radioGroup`, `segmentedControl`, `slider`, `textInputField`, `textArea`, `field`, `badge`, `divider`, `card`, `progress`, `progressCircle`, `collapsible`, `accordion`, `combobox`, `select`, `dialog`, `toast` / `ToastStack`, `Tooltip`, `Popover`, `HoverCard`, `ContextMenu` / `Menu`, `PopupList`, `RollingText`, `ScrollBar`, `Search`, `ShortcutRecorder`, `ImageZoom`, `Shell` (`Sidebar`, `TabStrip`, `WindowTitlebar`, `PaneState`, `splitView`, `toolbar`), `tree`, `table`, streaming `MarkdownParser` / `markdown`, `Kit.syntax` (`RuneHighlights`), `Kit.mermaid` (`RuneMermaid`), and `FileDiff` / `diffView`. |
| `RuneNotify` | `RuneNotify` | `crates/rune-notify` | System notifications through Apple UserNotifications, Windows WinRT toasts, and the freedesktop notification service on Linux. Supports replacement, removal, actions and clicks, and a deterministic test backend. |
| `RuneMac` | `RuneMac` | `crates/rune-mac` | macOS `NSWindow` frame persistence/autosave, multi-display clamping, fullscreen, relaunch, and notification helpers. |
| `RunePerf` | `RunePerf` | `crates/rune-perf` + `crates/procwatch` | Bounded local performance recording, Darwin `mach_task_basic_info` CPU/RSS telemetry, scoped spans/histograms, incident persistence, and Chrome Trace Event JSON export. |
| `RuneHighlights` | `RuneHighlights` | `crates/rune-highlights` | Zero-dependency multi-language syntax highlighter supporting 100+ languages with filename, shebang, and content detection. |
| `RuneFX` | `RuneFX` | `crates/rune-fx` | Special-effects layers, catalog/presets, `FireSim` ping-pong simulation, `MaskPyramid`, and Metal and OpenGL shaders (glow/bloom, pulses, electricity, procedural fire/embers, motion blur, distortion/ripple, chromatic aberration, vignette/grain). |
| `RuneLight` | `RuneLight` | `crates/rune-light` | Real-time 2D/2.5D lighting with Metal and OpenGL shaders (SDF soft shadows, bevel normals, point/directional/spot lights, god rays, radiance-cascade GI, glass refraction). |
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
| `rune-text-quality` | `RuneTextQuality` | `crates/rune/examples/text_quality.rs` | Run `swift run -c release rune-text-quality ./text-quality` to export 1× and 2× glyph images, subpixel phase sweeps and shaping measurements. |
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

## Build & Test

Requires **Swift 6.4+** (`// swift-tools-version: 6.4`, `swiftLanguageModes: [.v6]`). On macOS setups where `swiftly` is ahead of Xcode in `PATH`, use `xcrun swift` so the Xcode SDK and toolchain match:

```bash
# Run the package tests
xcrun swift test

# Build the libraries and executables
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

The same Swift view and runtime drive the Hello switch on desktop, Android, and the web. On the desktop, Rune draws its own controls in a native window and exposes their roles, values, and actions to the operating system’s accessibility service. The GPU draws instanced primitives and samples glyph and image atlases. Windows and Linux use OpenGL 3.3 core, Android uses OpenGL ES 3, browsers use WebGPU or WebGL 2, and Apple windows use Metal.

Applications can supply packed pixel surfaces and custom GPU effects. On Windows, `NativeSurface.pushShared(_:frameId:)` accepts named BGRA8 Direct3D textures on Rune’s adapter. The renderer uses WGL interop when the driver supports it and a staging copy otherwise. Native Vulkan rendering remains an upstream parity gap. [Windows shared-texture example](Tests/Support/WindowsSharedTexture) · [Upstream module map](.agents/skills/upstream-rune-sync/references/upstream-map.json)

On macOS, Windows, and X11, `WindowHandle.placement()` reports the window's position and content bounds in physical pixels. Wayland gives the compositor control of global placement, so this call returns `nil` there. For a click-through overlay on Wayland, use a borderless window so the input region covers the whole visible surface.

For a custom native GPU pass, attach a `Compositor` with `App.compositor(_:)` and mark its position in the view with `.effect(mark)`. Inside `render(frame:)`, `try frame.drawUI(withEffects:)` invokes your hook at each visible slot, before Rune paints later siblings. The hook receives the slot’s mark and device-pixel bounds, plus a Metal encoder on Apple or an OpenGL framebuffer and function resolver on Windows, Linux, and Android. Use `.effectBackdrop(true)` to sample earlier content. The target and backdrop belong to the current callback.

| Platform | Backend / Shell (`Sources/Rune/`) | Build Command |
| :--- | :--- | :--- |
| **macOS** (14+) | AppKit, CAMetalLayer, Metal, Core Text | `xcrun swift run rune-hello` |
| **iOS / iPadOS / tvOS / visionOS** (iOS 17+, tvOS 17+, visionOS 1+) | `IOSApp.swift` (`UIKit` / `CADisplayLink` / `Metal`) | `xcrun swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios17.0-simulator --target RuneKit` |
| **Windows** | Win32 window and input, WGL / OpenGL 3.3 core, DirectWrite | `swift run rune-hello` in a Swift 6.4 Windows developer environment |
| **Linux** | SDL2 on Wayland or X11, OpenGL 3.3 core, Pango / Cairo text, AT-SPI | `swift run rune-hello` in a graphical session |
| **Android** | NativeActivity, ANativeWindow, EGL / OpenGL ES 3, Choreographer | [Build the ARM64 library and install the APK](examples/android/README.md) |
| **WebAssembly** (`wasm32-unknown-wasip1`) | `WebPlatform.swift` (WASI reactor, DOM input, instanced WebGPU and WebGL 2 renderers) | `./scripts/build-web.sh <wasip1-sdk> rune-hello` |

On Ubuntu, install the native development packages before building.

```sh
sudo apt install pkg-config libsdl2-dev libegl-dev libgles-dev libgl1-mesa-dri libpango1.0-dev libgtk-3-dev libgtk-layer-shell0 libxi-dev libatk-bridge2.0-dev libx11-dev libx11-xcb-dev libxcb1-dev libxext-dev libxkbcommon-dev libwayland-dev libwebp-dev liblcms2-dev libgstreamer-plugins-base1.0-dev
RUNE_GPU_INFO=1 swift run rune-hello
```

On Linux, `OverlayHandle` uses a transparent OpenGL surface on composited X11 or a native layer surface on Wayland compositors that advertise `zwlr_layer_shell_v1`. The Wayland host uses `libgtk-layer-shell.so.0`, provided by Ubuntu’s `libgtk-layer-shell0` package. On compositors without layer-shell, an overlay with `.keyPolicy = .none` can use XWayland for a pass-through surface. An interactive XWayland overlay also requires `.xwaylandInput(true)`. Check the handle’s `availability` and `failure` after showing it.

The default `DesktopMedia` package trait enables playback and recording. Linux uses GStreamer. Windows uses Media Foundation for playback and AAC encoding and WASAPI for microphone input. On Ubuntu, install `gstreamer1.0-plugins-base`, `gstreamer1.0-plugins-good`, and `gstreamer1.0-libav` for AAC and H.264 playback. Install `gstreamer1.0-pulseaudio` for PulseAudio or PipeWire-Pulse output and microphone input, or `gstreamer1.0-alsa` for ALSA output. Recording M4A also needs an AAC encoder and MP4 muxer. For a UI-only build, use `swift build --disable-default-traits --product rune-hello`.

The Linux window smoke test checks the displayed label and switch pixels before and after input and resize. It requires `xvfb`, `xauth`, `xdotool`, `imagemagick`, `python3-xlib`, and a D-Bus session. Install `weston` for the Wayland test. Install `fonts-noto-color-emoji` for system color emoji. For system spelling suggestions, install `libenchant-2-2` and a dictionary such as `hunspell-en-us`.

```sh
swift build --product rune-hello
dbus-run-session -- xvfb-run -a python3 scripts/test-linux-window.py .build/debug/rune-hello
dbus-run-session -- xvfb-run -a python3 scripts/test-linux-window.py --wayland .build/debug/rune-hello
```

On Ubuntu with Swift 6.4.2, SwiftPM's native build system builds the full manifest and generates the Linux test runner. For a focused GPU check, run `swift test --build-system native --filter PortableGLRendererTests`. Run `swift test --build-system native` for the full suite.

On Windows, install the Swift toolchain, Visual C++ build tools, Windows SDK, and a display driver with OpenGL 3.3 support. Run the example from PowerShell. [Swift for Windows installation guide](https://www.swift.org/install/windows/manual/)

```powershell
$env:RUNE_GPU_INFO = "1"
swift run rune-hello
```

Click the switch and resize the window. The label changes from **Lights off** to **Lights on** and the switch stays centered. With `RUNE_GPU_INFO=1`, the host prints the API and device reported by the active context. Mesa's `llvmpipe` identifies a software driver.

To distribute a Windows build, keep SwiftPM's resource directories beside the executable. For Hello, `swift-rune_Rune.resources` contains the shaders and fonts. The executable also needs Swift runtime DLLs and the Microsoft Visual C++ v14 runtime for its architecture. Packaging the matching Swift DLLs and their notices beside the executable lets a user run it with the Visual C++ redistributable installed.

Windows notifications require an app identity. Call `RuneNotify.registerWithResult(.init(id: "com.example.app", name: "My App"))` during startup, or use `adoptWithResult` for an identity registered by the installer. Linux uses the desktop session’s notification service. Inline text replies depend on the service’s advertised capabilities. [Windows notification smoke test](Tests/Windows/Notifications/run.ps1) · [Private Linux notification test](scripts/test-linux-notifications.py)

To exercise lighting in an interactive app, run `swift run rune-light-live --scene chat`. To render one effects frame to a file, run `swift run rune-fx-gallery --still glow --snap glow.png`. On Windows, the UI Automation smoke test clicks the Hello switch, resizes the window and checks its accessible state. [Windows switch test](scripts/windows-uia-smoke.ps1) · [Windows text accessibility test](Tests/Support/WindowsTextAccessibility/Run.ps1)

To embed Rune in a UIKit app, set `window.rootViewController = try IOSApp.makeViewController(app)` in the scene delegate. On ProMotion iPhones, set the Boolean `CADisableMinimumFrameDurationOnPhone` to `YES` in the host app’s Info.plist to enable requests above 60 Hz. The Catalyst smoke test drives this controller through a real UIKit window. [UIKit window test](scripts/test-uikit-window.py)

To capture a UIKit window, pass `ToolingArgs.parse(["--native", "--trace", path, "--frames", "120"])` as the controller’s `parsed` argument. Choose a writable file in the app container. The trace records display-link targets and, on Metal devices and Mac Catalyst, drawable presentation times. Capture ends at the frame limit, window detachment, or backgrounding.

The Android example includes a NativeActivity manifest and a packaging script for Swift runtime libraries, resources, and Java input and accessibility bridges. [Build and run the Android app](examples/android/README.md)

`mountRuneFields(canvas, send)` in `Sources/Rune/Resources/Web/rune-web.mjs` mounts a native textarea and password field beside an existing canvas. Pass Rune’s `WebAppHost.onFieldChange` updates to its `sync(field, activate)` method and route its edit, selection and secure insert events to the corresponding `WebAppHost` handlers. Call `dispose()` when the canvas unmounts.

The browser entry uses a WASI Preview 1 reactor. Build with matching Swift compiler and WASI SDK versions. For example, Swift 6.4.2 can use the `swift-6.4.2-RELEASE_wasm` SDK. Release builds enable WebAssembly SIMD for geometry and color operations. To target an engine without SIMD, append `-Xcc -mno-simd128` to the build command.

```bash
./scripts/build-web.sh <wasip1-sdk> rune-web-hello -c release
```

Release builds strip debug symbols. With Swift 6.4.2, the optimized `rune-hello` sample's Wasm file measured 63.63 MiB, or 18.19 MiB served with Brotli compression at quality 7. The JavaScript modules, shaders, and fonts add separate requests.

Serve the resulting `.wasm` file and copy the `Web/`, `GL/`, and `Fonts/` directories from `Sources/Rune/Resources/` alongside it. The browser loads its shaders and bundled fonts relative to the JS modules. The following example assumes a WASI Preview 1 host with `wasiImport` and `initialize`.

```js
import { instantiateRuneBrowser, mountRuneBrowser } from './Web/rune-web.mjs';

const { instance } = await instantiateRuneBrowser(fetch('./rune-web-hello.wasm'), {
    wasi_snapshot_preview1: wasi.wasiImport
});
wasi.initialize(instance);
const app = mountRuneBrowser(document.querySelector('canvas'), instance);
await app.ready;
console.log(app.renderer);
// Call app.dispose() when the page removes the canvas.
```

The reactor built by `scripts/build-web.sh` imports `rune_text` for browser font shaping, mixed-direction caret positions and grayscale glyph masks. Pass `{ fontDirectory: null }` as the third argument to `instantiateRuneBrowser` to use fonts supplied by the page and system. A standalone WASI command built with regular `swift build` uses Rune’s bitmap fallback.

A resting browser app releases its animation-frame callback. Use `tx.wakeAfter(seconds)` to schedule the next poll, or call `waker.wake()` on the `Waker` supplied to `.setup` when external state changes. Swift tasks, input and resize events wake the app automatically. Continuous motion follows the display refresh rate.

To check spelling in a browser text field, add `.spellcheck()` to the field and pass `{ spellDictionaries: ["en-US", "de"] }` as the third argument to `instantiateRuneBrowser`. A Swift browser app can also call `SpellChecker.shared.setWebDictionaries(["en-US", "de"])`. Serve each Hunspell pair beside the page, for example `spell/en-US.aff` and `spell/en-US.dic`. Rune fetches the selected dictionaries and its bundled Spellbook engine when a field first checks text. `SpellChecker.shared.setLanguages(["de", "en-US"])` selects both languages explicitly. The field accepts words found in either dictionary, and learning a word applies throughout the mounted app.

The first browser frame uses the bundled Inter subsets in `Fonts/web/first/` and the original IBM Plex Mono. After presentation, Rune fetches all three full Inter weights from `Fonts/web/` and updates mounted windows together. An app that registers its own Inter keeps that family. Use `.fontUrl(...)` for a face the first frame needs, or `.fontUrlLater(...)` to fetch it after presentation. Both accept page-relative TrueType or OpenType URLs and read local font files on native platforms.

An app that uses `.webDocument()` lays out at its natural document height. The browser scrolls a band of rendered pixels with a 256-point skirt on each side. Rune repositions and redraws the band as the visible region approaches an edge. Use `.canvasId("article")` and call `mountRuneBrowser(null, instance)` to mount into that named canvas. Calling `.fullViewport()` on a named canvas makes it fill the browser window.

Use `ImageCache.load(data)` for encoded image bytes or `ImageCache.url("assets/logo.webp", sizePt: 32, scale: 2)` for a URL relative to the page. Both return a handle whose `.pixels` can be drawn immediately. Rune repaints when decoding finishes. The browser fetches remote assets under the page’s CORS rules. Rune uses compatible WebCodecs decoders and can composite animated GIF and WebP frames through browser image APIs when WebCodecs is unavailable. On the single-threaded browser reactor, use the cache’s `wake` callback or check `isReady` on a later frame before calling synchronous `wait()`.

A full-window app paints on a temporary CPU canvas while WebGPU starts and continues accepting input. The first completed GPU frame replaces it. Set `globalThis.RUNE_CPU_FIRST = "off"` to start on the GPU or `"only"` to keep a full-window app on the CPU. The browser sends packed Rune instances to WebGPU when it can acquire a device and compile the pipelines. It falls back to WebGL 2 during startup. Both backends upload complete atlases on first draw and after device or context restoration, then send changed glyph and image rectangles as the UI updates. Pass `{ backend: "webgpu" }` or `{ backend: "webgl2" }` to require one API. Custom effects supplied through `drawEffect` use WebGL, and `drawGPUEffect` receives the WebGPU command encoder. The canvas emits `runepresent` on its first draw, including an early CPU frame. `app.ready` resolves once backend startup finishes. `app.renderer` reports the actual adapter when the browser exposes its identity. The canvas follows its CSS size and device pixel ratio. Pass `{ resizeTo: element }` to size it from a containing element. For the reference rasterizer, request `{ backend: "cpu" }` on a fresh canvas. The focused editor uses a native textarea or password field for keyboard, IME, and assistive input.

A Swift `App.compositor` can animate, hide the UI, or request multiple `drawUI()` passes. To implement an authored effect in a browser, supply a synchronous `drawEffect(pass)` or `drawGPUEffect(pass)` mount option. A WebGPU effect receives the device, command encoder and target texture view. Rune calls it in painter order for visible `.effect(...)` slots. `pass.mark` identifies the slot. The callback can draw with `pass.gl` into `pass.framebuffer` using top-left device-pixel `rect`, `clip`, and target `origin`. A slot that requests a backdrop receives the earlier content as `pass.backdrop`. The framebuffer and snapshot texture are borrowed for that call.

Run the browser regression suite with Node 22 or later and Chrome or Chromium. To include the compiled Swift app, pass the WASI product and the `dist` directory of a locally installed `@bjorn3/browser_wasi_shim`. The runner opens an isolated browser profile, clicks the Lights switch, checks its accessibility state, reads back GPU pixels, and resizes the canvas.

```sh
node Tests/Browser/run.mjs --webgpu --wasm /path/to/rune-hello.wasm --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist
```

For the font asset checks, run `python3 Tests/Browser/font-assets.py` with fontTools installed and HarfBuzz’s `hb-shape` on the path. The checks compare character maps, advances, unhinted outlines and contextual shaping across the native, first-cut and full web Inter files.

To measure scrolling in the 100,000-row table and the 50,000-file tree with 500 expanded folders, build the release WASI products `rune-kit-table` and `rune-kit-tree`. The fixture measures frame intervals and Swift scene, accessibility and GPU submission times through the normal browser mount.

```sh
node Tests/Browser/run.mjs --fixture large-view-wasi --webgpu --compare-accessibility --device-scale 1 \
  --table-wasm /path/to/rune-kit-table.wasm --tree-wasm /path/to/rune-kit-tree.wasm \
  --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist
```

To check asynchronous Swift image loading, GIF playback, APNG composition and WebGL image pixels, build the small test app and pass its reactor to the same runner.

```sh
./scripts/build-web.sh swift-6.4.2-RELEASE_wasm rune-image-probe --package-path Tests/Browser/ImageApp
node Tests/Browser/run.mjs --fixture image-wasi --image-wasm /path/to/rune-image-probe.wasm --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist

./scripts/build-web.sh swift-6.4.2-RELEASE_wasm rune-image-page-probe --package-path Tests/Browser/ImageApp
node Tests/Browser/run.mjs --fixture image-pages-wasi --webgpu --image-page-wasm /path/to/rune-image-page-probe.wasm --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist

./scripts/build-web.sh swift-6.4.2-RELEASE_wasm rune-spell-probe --package-path Tests/Browser/SpellApp
node Tests/Browser/run.mjs --fixture spell-wasi --spell-wasm /path/to/rune-spell-probe.wasm --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist
```

To check browser clocks, seeded knobs, preferences and diagnostics in a real WebGPU window, run the diagnostics reactor with the same WASI shim.

```sh
./scripts/build-web.sh swift-6.4.2-RELEASE_wasm diagnostics-probe --package-path Tests/Browser/DiagnosticsApp
node Tests/Browser/run.mjs --fixture diagnostics-wasi --webgpu --diagnostics-wasm /path/to/diagnostics-probe.wasm --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist
```

### Tracing a desktop window

Run `swift run -c release rune-hello --native --trace frames.jsonl --frames 120` to capture 120 submissions and close the window. Omit `--frames` to capture an interactive session until the window closes. For a multi-window app, add `--window KEY` to select the window to trace.

Each JSONL frame records the elapsed milliseconds at CPU submission in `t`. On macOS, `target_ms` records the display-link target when available. A numeric `present_ms` is Metal’s drawable presentation time, and `null` means Metal reported that the drawable was skipped. Windows and Linux record submissions at the native present call. Their desktop traces omit drawable presentation times.

### Headless Rendering & Inspection

Any `RuneApp` executable accepts headless tooling flags (parsed by `ToolingArgs`):

```bash
# List available named scenes
xcrun swift run rune-hello --list-scenes

# Render a PNG snapshot of a named scene
xcrun swift run rune-hello --snap /tmp/hello-on.png --scene on --dark

# Compare CPU and GPU drawing at 100 ms and record damage for each frame
xcrun swift run rune-hello --snap /tmp/hello.png --at 0.1 --cpu-boot /tmp/rune-cpu-boot

# Dump the laid-out element tree to JSON
xcrun swift run rune-hello --tree /tmp/hello-tree.json

# Drive scripted input (JSON file or inline JSON) and capture frames
xcrun swift run rune-todo --script script.json --frames /tmp/frames --fps 60
```

The CPU capture directory contains `draw.bin` for replay, `cpu.png`, `gpu.png`, and `frames.jsonl` with timing and damaged tiles for every frame. The terminal reports the number of differing pixels. `--cpu-boot-threads N` selects the CPU painter’s worker count (six by default).

Supported flags: `--snap <path>`, `--tree <path>`, `--scene <name>`, `--list-scenes`, `--script <json|path>`, `--frames <dir>`, `--strip <path>`, `--fps <n>`, `--scale <n>`, `--time-scale <n>`, `--duration <sec>`, `--at <sec>`, `--start <sec>`, `--crop <x,y,w,h>`, `--every <n>`, `--theme <name>`, `--size <WxH>`, `--dark` / `--light`, `--reduced-motion`, `--cpu` (use the CPU reference renderer), and `--gpu` (require a working GPU backend).

Frame-phase profiling measures view, commit, layout, text, paint and apply time on the rendering thread. Set `RUNE_FRAME_PROFILE=1` before launch to measure the first frame, or wrap a synchronous workload in `FrameProfiling.withRecording { ... }`. Read and clear the six wall-time values and six CPU-time values with `takeFramePhases()`. Its first call also enables measurements for subsequent frames on that thread. Tracing enables automatic phase timing. Explicit `measureFramePhase` calls always measure their closure. Debug builds enable idle and callback stall warnings by default. Set `RUNE_PERF_WARN=1` to inspect them in a release build.

## Upstream Parity & Sync Workflow (`rune-parity` & `.agents/skills/upstream-rune-sync`)

`swift-rune` tracks upstream `anomalyco/rune` parity using the `.upstream-sync.json` state file, the `.agents/skills/upstream-rune-sync` skill and its module map, and the `rune-parity` CLI.

```bash
# 1. Check map coverage and the Swift paths referenced by the map
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

All `rune-parity` subcommands support `--json`. The `status` command checks that upstream files have a map entry and that referenced Swift paths exist. Entries marked `partial` or `missing` describe outstanding porting work. The `diff-commits` command reports mapped and unmapped changes. The `compare-renders` command exits nonzero when its visual or layout checks fail.

## License

MIT — see [LICENSE](LICENSE).
