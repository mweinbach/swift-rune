# Headless Testing, Profiling & Cross-Platform Deployment

Every `RuneApp` includes built-in headless rendering, deterministic virtual-clock input scripting, pixel/layout diffing, and frame-phase profiling—allowing you to test UIs in CI without a window server and ship the same Swift codebase across desktop, mobile, and WebAssembly.

---

## 1. Headless CLI Tooling (`ToolingArgs`)

Any executable launched with `RuneApp.run(...)` automatically parses headless CLI flags before creating a native window:

### Snapshots & Layout Trees

```bash
# List named scenes registered via AppSpec.scene(_:_:)
swift run MyApp --list-scenes

# Render a PNG snapshot at 2x scale in dark mode
swift run MyApp --snap out.png --scene on --dark --size 800x600 --scale 2

# Capture at an exact animation timestamp (in seconds)
swift run MyApp --snap mid-spring.png --scene on --at 0.12

# Crop the snapshot to a specific keyed element's bounds
swift run MyApp --snap card.png --crop main-card

# Dump the laid-out element tree, rects, styles, and accessibility metadata to JSON
swift run MyApp --tree layout.json

# Force the portable CPU reference renderer (ideal for CI without a GPU)
swift run MyApp --snap ref.png --cpu
```

### Complete Flag Reference

| Flag | Purpose |
| :--- | :--- |
| `--list-scenes` | Print all named `.scene(...)` presets |
| `--scene <name>` | Apply a named scene preset before rendering |
| `--snap <path>` | Render a PNG snapshot to `<path>` |
| `--tree <path>` | Write the laid-out element & accessibility tree JSON to `<path>` |
| `--script <json\|path>` | Run scripted pointer, keyboard, scroll, resize, or file-drop events |
| `--frames <dir>` | Render a frame sequence (`0000.png`, `0001.png`, ...) into `<dir>` |
| `--strip <path>` | Composite captured frames into a single horizontal filmstrip PNG |
| `--video <path>` | Encode captured frames to `.mp4`, `.mov`, or `.webm` (requires `ffmpeg` on `PATH`) |
| `--fps <n>` | Frame rate for `--frames`, `--strip`, or `--video` |
| `--at <sec>` | Single timestamp (or mark expression like `afterClick+0.15`) for `--snap` |
| `--start <sec>` / `--duration <sec>` | Capture time window |
| `--time-scale <n>` | Slow down or speed up animations |
| `--size <WxH>` / `--scale <n>` | Override logical viewport dimensions and HiDPI backing scale |
| `--crop <key>` | Crop `--snap` output to a keyed element |
| `--dark` / `--light` | Override OS appearance |
| `--reduced-motion` | Enable reduced-motion mode |
| `--cpu` / `--gpu` | Force the portable CPU rasterizer or require a hardware GPU backend |
| `--cpu-boot <dir>` | Compare CPU vs GPU rendering and record per-frame tile damage |

---

## 2. Scripted Interaction Testing (`--script`)

Drive deterministic UI flows using inline JSON or a `.json` file. Events target elements either by their `.key("...")` or by `(x, y)` coordinates:

```json
[
  { "t": 0.05, "type": "click", "key": "name-input" },
  { "t": 0.15, "type": "type", "text": "Rune", "every": 0.03 },
  { "t": 0.40, "type": "click", "key": "dark-switch" },
  { "t": 0.55, "type": "drag", "key": "speed-slider", "dx": 80, "dur": 0.25 },
  { "t": 0.90, "shortcut": "mod+s" }
]
```

Run it headless to verify behavior or produce a visual filmstrip / video:

```bash
swift run MyApp --script flow.json --strip flow-strip.png --fps 15 --duration 1.2
swift run MyApp --script flow.json --snap final.png --at 1.1 --tree final-tree.json
```

Supported script event types include:
- Pointer: `"move"`, `"down"`, `"up"`, `"click"`/`"tap"`, `"double-click"`, `"triple-click"`, `"secondary-click"`, `"drag"` (`dx`, `dy`, `dur`)
- Keyboard & Clipboard: `"type"` (`text`, `every`), `"key"` / `"key-up"` (`name`, `cmd`/`ctrl`/`shift`/`alt`), `"shortcut"` (`"mod+shift+k"`), `"paste"` (string or `{ "text", "html", "rtf", "png" }`)
- Window & OS: `"focus"` (`true`/`false`), `"open_url"`, `"drag_files"` / `"drop_files"`

---

## 3. Writing Swift Unit Tests (`HeadlessRunner` & `RuneRef`)

Because `Rune` re-exports `RuneRef`, you can render frames in-process inside XCTest / Swift Testing targets and assert both layout properties and pixel parity:

```swift
import Testing
import Rune

@Test func switchTogglesAndRendersCleanly() throws {
    let spec = AppSpec<HelloState>(
        title: "Test",
        size: Vec2(320, 200),
        state: HelloState(),
        view: helloView
    )
    .scene("on") { $0.on = true }

    let offArgs = ToolingArgs.parse(["--cpu", "--snap", "/tmp/off.png"])
    let onArgs  = ToolingArgs.parse(["--cpu", "--scene", "on", "--snap", "/tmp/on.png"])

    _ = try HeadlessRunner.run(spec, args: offArgs)
    _ = try HeadlessRunner.run(spec, args: onArgs)

    let offFrame = try Frame.decodePNG(Data(contentsOf: URL(fileURLWithPath: "/tmp/off.png")))
    let onFrame  = try Frame.decodePNG(Data(contentsOf: URL(fileURLWithPath: "/tmp/on.png")))
    let diff = RuneRef.diff(offFrame, onFrame)

    #expect(diff.differingPixels > 0)
}
```

---

## 4. Frame Profiling & Performance Tracing

### Phase Timings

Measure view build, commit, layout, text shaping, paint, and GPU apply timings on the render thread:

```bash
RUNE_FRAME_PROFILE=1 swift run -c release MyApp
```

Or programmatically in benchmarks and tests:

```swift
FrameProfiling.withRecording {
    // Run workload
}
let phases = takeFramePhases()
```

### Live Frame-Pacing Traces

Capture submission and presentation timestamps from a real desktop window:

```bash
swift run -c release MyApp --native --trace frames.jsonl --frames 120
```

Each JSONL entry records CPU submission time (`t`), display-link target (`target_ms` on macOS), and Metal drawable presentation time (`present_ms`). For deeper CPU/RSS telemetry and Chrome Trace Event JSON export (`chrome://tracing` / Perfetto), add `.product(name: "RunePerf", package: "swift-rune")`.

---

## 5. Cross-Platform Deployment Checklists

### macOS (14+)
- Uses **AppKit + Metal + Core Text + NSAccessibility**.
- Build release binary: `xcrun swift build -c release`
- Bundle SwiftPM's resource bundle (`swift-rune_Rune.resources` / `*.bundle`) inside your `.app/Contents/Resources/` directory.
- Optional: add `RuneMac` for window frame autosave across multi-display setups.

### iOS / iPadOS / tvOS / visionOS (iOS 17+)
- Uses **UIKit + CADisplayLink + Metal + Core Text + UIAccessibility**.
- Embed your Rune app in a `UIWindowSceneDelegate`:
  ```swift
  window.rootViewController = try IOSApp.makeViewController(app)
  ```
- Add `CADisableMinimumFrameDurationOnPhone = YES` to `Info.plist` for 120 Hz ProMotion displays.

### Windows (10/11)
- Uses **Win32 + WGL / OpenGL 3.3 Core + DirectWrite + UI Automation**.
- Set `RUNE_GPU_INFO=1` during development to verify hardware OpenGL context creation (vs software `llvmpipe`).
- For distribution, ship beside your `.exe`:
  1. SwiftPM resource directories (e.g. `swift-rune_Rune.resources/` containing shaders and fonts)
  2. Matching Swift runtime DLLs (from the Swift Windows runtime redistributable)
  3. Target machines need the Microsoft Visual C++ v14 Redistributable.
- If using `RuneNotify`, register an app identity at startup via `RuneNotify.registerWithResult(.init(id: "...", name: "..."))`.

### Linux (Wayland & X11)
- Uses **SDL2 + OpenGL 3.3 Core + Pango/Cairo + AT-SPI**.
- Install native dev packages on Ubuntu/Debian:
  ```sh
  sudo apt install pkg-config libsdl2-dev libegl-dev libgles-dev libgl1-mesa-dri \
    libpango1.0-dev libgtk-3-dev libgtk-layer-shell0 libxi-dev libatk-bridge2.0-dev \
    libx11-dev libx11-xcb-dev libxcb1-dev libxext-dev libxkbcommon-dev \
    libwayland-dev libwebp-dev liblcms2-dev libgstreamer-plugins-base1.0-dev
  ```
- For UI-only builds without GStreamer, set `traits: []` on your `swift-rune` dependency in `Package.swift`.
- Keep SwiftPM resource bundles alongside the compiled binary when packaging.

### Android (API 24+)
- Uses **NativeActivity + EGL / OpenGL ES 3 + Choreographer + Android AccessibilityNodeProvider**.
- Export `ANativeActivity_onCreate` from a dynamic library target and call `AndroidApp.attach(to:spec:)` (see `Sources/Examples/RuneHelloAndroid/Activity.swift` and [`examples/android/README.md`](../examples/android/README.md)).
- Package `.so`, Swift Android runtime libraries, Java host classes, shaders, and fonts with `scripts/package-android-hello.py`.

### WebAssembly (`wasm32-unknown-wasip1`)
- Uses a **WASI Preview 1 reactor + WebGPU / WebGL 2 / CPU canvas + DOM/ARIA bridge**.
- Build an optimized WASI reactor:
  ```bash
  ./scripts/build-web.sh <wasip1-sdk> my-web-app -c release
  ```
- Serve the `.wasm` file beside `Web/`, `GL/`, and `Fonts/` copied from `Sources/Rune/Resources/` and mount it via `instantiateRuneBrowser` / `mountRuneBrowser` in `Web/rune-web.mjs`:
  ```js
  import { instantiateRuneBrowser, mountRuneBrowser } from './Web/rune-web.mjs';

  const { instance } = await instantiateRuneBrowser(fetch('./my-web-app.wasm'), {
    wasi_snapshot_preview1: wasi.wasiImport,
  });
  wasi.initialize(instance);
  const app = mountRuneBrowser(document.querySelector('canvas'), instance);
  await app.ready;
  ```
- Use `.webDocument()` for natural page scrolling, `.canvasId("...")` to mount into a specific `<canvas>`, and `.fullViewport()` to fill the browser window.
