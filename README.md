# swift-rune

A Swift 6.4 port of [anomalyco/rune](https://github.com/anomalyco/rune), a GPU-rendered declarative UI framework for **macOS**, **iOS / iPadOS / tvOS / visionOS**, **Windows**, **Linux**, **Android**, and **WebAssembly (`wasm32-unknown-wasip1`)**, with its own layout engine, analytic spring & scene animation runtime, glyph atlas, CPU reference rasterizer, and component kit.

Every `RuneApp` supports headless execution (`--snap`, `--tree`, `--script`, `--frames`, `--strip`) so UIs and automated tests can render PNGs, inspect the element tree, and drive scripted input without a window.

## Architecture & Upstream Mapping

`swift-rune` is organized as a SwiftPM workspace mirroring the crates of upstream `anomalyco/rune`:

| SwiftPM Target | Product | Upstream Crate | Responsibility |
| :--- | :--- | :--- | :--- |
| `RuneMotion` | `RuneMotion` | `crates/rune-motion` | Analytic `Spring(duration:bounce:)`, `Easing` / `CubicBezier`, `Decay`, `KeyframeTrack`, `AnimationStore` (velocity-preserving retargeting, merge/additive blending, premultiplied OKLab color interpolation), `Scene` (4-edge layout morphing, `Transition` enter/exit presence, `reducedMotion`), `Choreography`, `PhaseAnimator`, `Stagger`, `Sequence`/`Beat`, `Cycle`/`LoopTrack`, `VelocityTracker` / rubber-band gestures, `Animated`, `MotionTrace`, and `Clock`. |
| `RuneRef` | `RuneRef` | `crates/rune-ref` | CPU reference rasterizer (`RuneRef.render`) implementing the exact uber-shader primitive set (`Primitive`, `RefScene`, `R8Atlas`, `RGBA8Atlas`), `Frame` PNG encode/decode, pixel-level `RuneRef.diff` (`Difference`, `PixelBlame`), and `rune-ref` CLI (`generate`, `check` GPU-vs-CPU differential parity). |
| `RuneI18n` | `RuneI18n` | `crates/rune-i18n` | BCP-47 `LocaleInfo` parsing, RTL detection, script-aware `negotiateLocale`, system locale detection, CLDR `PluralCategory` rules, number/list formatting, `Template` (`{{name}}` interpolation), JSON `Catalog.fromJSON`, and `I18n` runtime lookup. |
| `RuneTaffy` | `RuneTaffy` | `crates/rune-taffy` | Standalone CSS Flexbox, CSS Grid, Block, and Absolute layout engine (`LayoutEngine`, `TaffyStyle`, `MeasureFunc`, `LayoutCache`, dirty propagation, `roundLayout`). |
| `Rune` | `Rune` | `crates/rune` | Declarative `El<State>` view tree (`row`, `col`, `el`, `text`, `liveText`, `rich`, `icon`, `image`, `canvas`, `textInput`), `Tok` / `JsonTheme` OKLCH design tokens, `LayoutEngine` (flexbox, CSS Grid, block, virtualized growth stacks), `TextEdit` Unicode grapheme editor & `Keybind`, `Shape` / `VectorPath` ear-clipped polygons & strokes, `Live<T>` / `Binding<T>` / `Tween<T>`, `Machine` (`Attempt`, `Seq`, `Effects`), Metal, OpenGL, OpenGL ES and WebGL 2 rendering, a portable CPU reference renderer, and native and browser app hosts, accessibility bridge, rich clipboard, file dialogs, spellcheck, and `HeadlessRunner`. |
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

For a SwiftPM app beside this checkout, add `.package(path: "../swift-rune")` to the package dependencies and `.product(name: "Rune", package: "swift-rune")` to the executable target. An app using the component kit can also add the `RuneKit` product. Put the following in `main.swift`.

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

To use RuneKit controls in the same app, add the `RuneKit` product and pass `settingsView` as the `AppSpec` view.

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
    kit.card(
        key: "panel",
        col().gap(12)
            .child(text("Settings").font(kit.ty.uiMedium).color(kit.c.textBase))
            .child(kit.divider())
            .child(kit.switchControl(key: "toggle", isOn: state.on, label: "Lights") { state, isOn in
                state.on = isOn
            })
    )
}
```

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

The same Swift view and runtime drive the Hello switch on desktop, Android, and the web. On the desktop, Rune draws its own controls in a native window and exposes their roles, values, and actions to the operating system’s accessibility service. The GPU draws instanced primitives and samples glyph and image atlases. Windows and Linux use OpenGL 3.3 core, Android uses OpenGL ES 3, browsers use WebGL 2, and Apple windows use Metal.

Applications can supply packed pixel surfaces and custom GPU effects. Direct3D texture sharing, native Vulkan and WebGPU integration require additional backends. The upstream map tracks remaining implementation differences at module level. [Upstream module map](.agents/skills/upstream-rune-sync/references/upstream-map.json)

On macOS, Windows, and X11, `WindowHandle.placement()` reports the window's position and content bounds in physical pixels. Wayland gives the compositor control of global placement, so this call returns `nil` there. For a click-through overlay on Wayland, use a borderless window so the input region covers the whole visible surface.

For a custom native GPU pass, attach a `Compositor` with `App.compositor(_:)` and mark its position in the view with `.effect(mark)`. Inside `render(frame:)`, `try frame.drawUI(withEffects:)` invokes your hook at each visible slot, before Rune paints later siblings. The hook receives the slot’s mark and device-pixel bounds, plus a Metal encoder on Apple or an OpenGL framebuffer and function resolver on Windows, Linux, and Android. Use `.effectBackdrop(true)` to sample earlier content. The target and backdrop belong to the current callback.

| Platform | Backend / Shell (`Sources/Rune/`) | Build Command |
| :--- | :--- | :--- |
| **macOS** (14+) | AppKit, CAMetalLayer, Metal, Core Text | `xcrun swift run rune-hello` |
| **iOS / iPadOS / tvOS / visionOS** (iOS 17+, tvOS 17+, visionOS 1+) | `IOSApp.swift` (`UIKit` / `CADisplayLink` / `Metal`) | `xcrun swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios17.0-simulator --target RuneKit` |
| **Windows** | Win32 window and input, WGL / OpenGL 3.3 core, DirectWrite | `swift run rune-hello` in a Swift 6.4 Windows developer environment |
| **Linux** | SDL2 on Wayland or X11, OpenGL 3.3 core, Pango / Cairo text, AT-SPI | `swift run rune-hello` in a graphical session |
| **Android** | NativeActivity, ANativeWindow, EGL / OpenGL ES 3, Choreographer | [Build the ARM64 library and install the APK](examples/android/README.md) |
| **WebAssembly** (`wasm32-unknown-wasip1`) | `WebPlatform.swift` (WASI reactor, DOM input, WebGL 2 instanced renderer) | `./scripts/build-web.sh <wasip1-sdk> rune-hello` |

On Ubuntu, install the native development packages before building.

```sh
sudo apt install pkg-config libsdl2-dev libegl-dev libgles-dev libgl1-mesa-dri libpango1.0-dev libgtk-3-dev libatk-bridge2.0-dev libx11-dev libx11-xcb-dev libxcb1-dev libxext-dev libxkbcommon-dev libwayland-dev libwebp-dev liblcms2-dev libgstreamer-plugins-base1.0-dev
RUNE_GPU_INFO=1 swift run rune-hello
```

The default `DesktopMedia` package trait enables playback and recording. Linux uses GStreamer. Windows uses Media Foundation for playback and AAC encoding and WASAPI for microphone input. On Ubuntu, install `gstreamer1.0-plugins-base`, `gstreamer1.0-plugins-good`, and `gstreamer1.0-libav` for AAC and H.264 playback. Install `gstreamer1.0-pulseaudio` for PulseAudio or PipeWire-Pulse output and microphone input, or `gstreamer1.0-alsa` for ALSA output. Recording M4A also needs an AAC encoder and MP4 muxer. For a UI-only build, use `swift build --disable-default-traits --product rune-hello`.

The Linux window smoke test checks the displayed label and switch pixels before and after input and resize. It requires `xvfb`, `xauth`, `xdotool`, `imagemagick`, `python3-xlib`, and a D-Bus session. Install `weston` for the Wayland test. Install `fonts-noto-color-emoji` for system color emoji. For system spelling suggestions, install `libenchant-2-2` and a dictionary such as `hunspell-en-us`.

```sh
swift build --product rune-hello
dbus-run-session -- xvfb-run -a python3 scripts/test-linux-window.py .build/debug/rune-hello
dbus-run-session -- xvfb-run -a python3 scripts/test-linux-window.py --wayland .build/debug/rune-hello
```

On Windows, install the Swift toolchain, Visual C++ build tools, Windows SDK, and a display driver with OpenGL 3.3 support. Run the example from PowerShell. [Swift for Windows installation guide](https://www.swift.org/install/windows/manual/)

```powershell
$env:RUNE_GPU_INFO = "1"
swift run rune-hello
```

Click the switch and resize the window. The label changes from **Lights off** to **Lights on** and the switch stays centered. With `RUNE_GPU_INFO=1`, the host prints the API and device reported by the active context. Mesa's `llvmpipe` identifies a software driver.

Windows notifications require an app identity. Call `RuneNotify.registerWithResult(.init(id: "com.example.app", name: "My App"))` during startup, or use `adoptWithResult` for an identity registered by the installer. Linux uses the desktop session’s notification service. Inline text replies depend on the service’s advertised capabilities. [Windows notification smoke test](Tests/Windows/Notifications/run.ps1) · [Private Linux notification test](scripts/test-linux-notifications.py)

To exercise lighting in an interactive app, run `swift run rune-light-live --scene chat`. To render one effects frame to a file, run `swift run rune-fx-gallery --still glow --snap glow.png`. On Windows, the UI Automation smoke test clicks the Hello switch, resizes the window and checks its accessible state. [Windows switch test](scripts/windows-uia-smoke.ps1) · [Windows text accessibility test](Tests/Support/WindowsTextAccessibility/Run.ps1)

To embed Rune in a UIKit app, set `window.rootViewController = try IOSApp.makeViewController(app)` in the scene delegate. The Catalyst smoke test drives this controller through a real UIKit window. [UIKit window test](scripts/test-uikit-window.py)

The Android example includes a NativeActivity manifest and a packaging script for Swift runtime libraries, resources, and Java input and accessibility bridges. [Build and run the Android app](examples/android/README.md)

`mountRuneFields(canvas, send)` in `Sources/Rune/Resources/Web/rune-web.mjs` mounts a native textarea and password field beside an existing canvas. Pass Rune’s `WebAppHost.onFieldChange` updates to its `sync(field, activate)` method and route its edit, selection and secure insert events to the corresponding `WebAppHost` handlers. Call `dispose()` when the canvas unmounts.

The browser entry uses a WASI Preview 1 reactor. Build with matching Swift compiler and WASI SDK versions. For example, Swift 6.4.2 can use the `swift-6.4.2-RELEASE_wasm` SDK.

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

Use `ImageCache.load(data)` for encoded image bytes or `ImageCache.url("assets/logo.webp", sizePt: 32, scale: 2)` for a URL relative to the page. Both return a handle whose `.pixels` can be drawn immediately. Rune repaints when decoding finishes. The browser fetches remote assets under the page’s CORS rules. Rune uses compatible WebCodecs decoders and can composite animated GIF and WebP frames through browser image APIs when WebCodecs is unavailable. On the single-threaded browser reactor, use the cache’s `wake` callback or check `isReady` on a later frame before calling synchronous `wait()`.

The default browser renderer sends packed Rune instances to WebGL 2. It uploads complete atlases on first draw and after context restoration, then sends changed glyph and image rectangles as the UI updates. `app.ready` resolves after the first draw. `app.renderer` reports the actual adapter when the browser exposes its identity. The canvas follows its CSS size and device pixel ratio. Pass `{ resizeTo: element }` to size it from a containing element. For the reference rasterizer, request `{ backend: "cpu" }` on a fresh canvas. The focused editor uses a native textarea or password field for keyboard, IME, and assistive input.

A Swift `App.compositor` can animate, hide the UI, or request multiple `drawUI()` passes. To implement an authored effect in a browser, supply a synchronous `drawEffect(pass)` mount option. Rune calls it in painter order for visible `.effect(...)` slots. `pass.mark` identifies the slot. The callback can draw with `pass.gl` into `pass.framebuffer` using top-left device-pixel `rect`, `clip`, and target `origin`. A slot that requests a backdrop receives the earlier content as `pass.backdrop`. The framebuffer and snapshot texture are borrowed for that call.

Run the browser regression suite with Node 22 or later and Chrome or Chromium. To include the compiled Swift app, pass the WASI product and the `dist` directory of a locally installed `@bjorn3/browser_wasi_shim`. The runner opens an isolated browser profile, clicks the Lights switch, checks its accessibility state, reads back GPU pixels, and resizes the canvas.

```sh
node Tests/Browser/run.mjs --wasm /path/to/rune-hello.wasm --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist
```

To check asynchronous Swift image loading, GIF playback, APNG composition and WebGL image pixels, build the small test app and pass its reactor to the same runner.

```sh
./scripts/build-web.sh swift-6.4.2-RELEASE_wasm rune-image-probe --package-path Tests/Browser/ImageApp
node Tests/Browser/run.mjs --fixture image-wasi --image-wasm /path/to/rune-image-probe.wasm --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist
```

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

Supported flags: `--snap <path>`, `--tree <path>`, `--scene <name>`, `--list-scenes`, `--script <json|path>`, `--frames <dir>`, `--strip <path>`, `--fps <n>`, `--scale <n>`, `--time-scale <n>`, `--duration <sec>`, `--at <sec>`, `--start <sec>`, `--crop <x,y,w,h>`, `--every <n>`, `--theme <name>`, `--size <WxH>`, `--dark` / `--light`, `--reduced-motion`, `--cpu` (use the CPU reference renderer), and `--gpu` (require a working GPU backend).

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
