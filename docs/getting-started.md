# Getting Started with swift-rune

`swift-rune` is a SwiftPM package for building GPU-rendered, cross-platform declarative UIs in **Swift 6.4+**. The same view tree runs natively on **macOS**, **iOS / iPadOS / tvOS / visionOS**, **Windows**, **Linux**, **Android**, and **WebAssembly (`wasm32-unknown-wasip1`)**, plus headless mode for automated visual testing.

## Requirements

- **Swift 6.4+** (`swift-tools-version: 6.4`, Swift 6 language mode)
- **Apple platforms**: macOS 14+, iOS 17+, tvOS 17+, visionOS 1+ (Metal + Core Text)
- **Windows**: Swift 6.4 Windows toolchain, Visual C++ Build Tools, Windows SDK, OpenGL 3.3+ driver
- **Linux**: OpenGL 3.3+ driver and system dev packages (SDL2, GTK3, Pango/Cairo, ATK, X11/Wayland; see [Platform Setup](#platform-setup))

## 1. Create a New SwiftPM App

```bash
mkdir MyRuneApp && cd MyRuneApp
swift package init --type executable --name MyRuneApp
```

Replace `Package.swift` with:

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MyRuneApp",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    dependencies: [
        .package(url: "https://github.com/mweinbach/swift-rune.git", from: "0.1.0"),
        // Or track main directly:
        // .package(url: "https://github.com/mweinbach/swift-rune.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MyRuneApp",
            dependencies: [
                .product(name: "Rune", package: "swift-rune"),
                .product(name: "RuneKit", package: "swift-rune"),
                // Optional add-ons:
                // .product(name: "RuneFX", package: "swift-rune"),
                // .product(name: "RuneLight", package: "swift-rune"),
                // .product(name: "RuneNotify", package: "swift-rune"),
                // .product(name: "OpenCodeTheme", package: "swift-rune"),
            ]
        ),
    ]
)
```

> **Note:** `Rune` automatically re-exports `RuneMotion` and `RuneRef`, so importing `Rune` gives you springs, easing, layout animations, and the reference rasterizer out of the box.

### UI-Only Builds (Disabling Desktop Media Dependencies)

By default, `swift-rune` enables the `DesktopMedia` package trait for audio/video playback and microphone recording on Windows and Linux. If your app only needs UI and you want to avoid linking GStreamer on Linux, disable default traits:

```swift
.package(
    url: "https://github.com/mweinbach/swift-rune.git",
    from: "0.1.0",
    traits: []
)
```

Or when building directly inside the `swift-rune` checkout:

```bash
swift build --disable-default-traits --product rune-hello
```

## 2. Write Your First UI

Put the following in `Sources/MyRuneApp/MyRuneApp.swift`:

```swift
import Rune
import RuneKit

struct AppState {
    var count: Int = 0
    var darkMode: Bool = true
    var name: TextEdit = TextEdit("World")
}

func appView(_ state: AppState, _ cx: inout Cx<AppState>) -> El<AppState> {
    let kit = Kit.fromPalette(
        PaletteSeed(
            bg: state.darkMode ? Color.hex("#111318")! : Color.hex("#f7f8fa")!,
            fg: state.darkMode ? Color.hex("#f1f3f5")! : Color.hex("#181b20")!,
            accent: Tok.accent(0, dark: state.darkMode)
        ),
        focus: .accent
    )

    let greeting = state.name.text.isEmpty ? "World" : state.name.text

    return col()
        .sizeFull()
        .center()
        .p(24)
        .bg(kit.c.page)
        .child(
            kit.card(
                key: "main-card",
                col()
                    .w(360)
                    .gap(14)
                    .child(
                        row()
                            .wFull()
                            .itemsCenter()
                            .justifyBetween()
                            .child(text("Hello, \(greeting)!").font(kit.ty.bodyMedium).color(kit.c.textBase))
                            .child(kit.badge("Count: \(state.count)", tone: .accent))
                    )
                    .child(kit.divider())
                    .child(
                        kit.field(
                            label: "Your name",
                            control: kit.textInputField(
                                key: "name-input",
                                \AppState.name,
                                placeholder: "Enter a name"
                            )
                        )
                    )
                    .child(
                        row()
                            .wFull()
                            .itemsCenter()
                            .justifyBetween()
                            .child(text("Dark mode").font(kit.ty.ui).color(kit.c.textMuted))
                            .child(
                                kit.switchControl(
                                    key: "dark-switch",
                                    isOn: state.darkMode,
                                    label: "Dark mode"
                                ) { state, isOn in
                                    state.darkMode = isOn
                                }
                            )
                    )
                    .child(
                        row()
                            .gap(8)
                            .child(
                                kit.button(key: "inc", "Increment", variant: .primary) { state, _ in
                                    state.count += 1
                                }
                            )
                            .child(
                                kit.button(key: "reset", "Reset", variant: .neutral) { state, _ in
                                    state.count = 0
                                }
                            )
                    )
            )
        )
}

@main
enum MyRuneApp {
    static func main() {
        let spec = AppSpec<AppState>(
            title: "My Rune App",
            size: Vec2(460, 340),
            minSize: Vec2(380, 280),
            state: AppState(),
            view: appView
        )
        .scene("light") { $0.darkMode = false }
        .scene("counted") { $0.count = 42 }

        RuneApp.runOrExit(spec)
    }
}
```

## 3. Run & Inspect Your App

### Run Interactively

```bash
# macOS (use xcrun swift when swiftly is ahead of Xcode in PATH)
xcrun swift run

# Windows / Linux
swift run
```

### Render Headless Snapshots (No Window Required)

Every `RuneApp` automatically parses headless CLI flags via `ToolingArgs`, which makes visual QA and CI testing trivial:

```bash
# List named scenes registered on AppSpec
swift run MyRuneApp --list-scenes

# Render a PNG snapshot of the default scene or a named scene
swift run MyRuneApp --snap out.png
swift run MyRuneApp --snap light.png --scene light

# Dump the laid-out element tree to JSON
swift run MyRuneApp --tree tree.json
```

## 4. Platform Setup

### macOS & Apple Platforms

No extra system libraries are required.

- **macOS**: `xcrun swift run`
- **iOS / iPadOS / tvOS / visionOS**: Embed Rune in UIKit by setting `window.rootViewController = try IOSApp.makeViewController(app)` in your scene delegate. On ProMotion iPhones, add `CADisableMinimumFrameDurationOnPhone = YES` to `Info.plist` for >60 Hz refresh rates.

### Windows

Install the [Swift 6.4 Windows toolchain](https://www.swift.org/install/windows/manual/), Visual C++ Build Tools, Windows SDK, and an OpenGL 3.3+ graphics driver.

```powershell
$env:RUNE_GPU_INFO = "1"
swift run
```

When distributing a Windows binary, keep SwiftPM's resource bundles (such as `swift-rune_Rune.resources`) next to the executable along with the Swift runtime DLLs.

### Linux (Ubuntu / Debian)

Install native development dependencies before building:

```sh
sudo apt install pkg-config libsdl2-dev libegl-dev libgles-dev libgl1-mesa-dri \
  libpango1.0-dev libgtk-3-dev libgtk-layer-shell0 libxi-dev libatk-bridge2.0-dev \
  libx11-dev libx11-xcb-dev libxcb1-dev libxext-dev libxkbcommon-dev \
  libwayland-dev libwebp-dev liblcms2-dev libgstreamer-plugins-base1.0-dev
```

For UI-only builds (`--disable-default-traits`), `libgstreamer-plugins-base1.0-dev` is not needed.

### WebAssembly & Android

- **WebAssembly (`wasm32-unknown-wasip1`)**: Build a WASI reactor with `./scripts/build-web.sh <wasip1-sdk> <product> -c release` and mount it with `Web/rune-web.mjs` (see the [README](../README.md#cross-platform-architecture--builds)).
- **Android**: Export `ANativeActivity_onCreate` and call `AndroidApp.attach(to:spec:)` (see [`examples/android/README.md`](../examples/android/README.md)).

## Next Steps

- [Core UI, Layout & Styling Guide](ui-guide.md) — Flexbox, CSS Grid, colors/tokens, vector shapes, images, and scrolling.
- [State, Events & Architecture](state-and-architecture.md) — `AppSpec` vs `App`, `AppHandle`, `Cx`/`Tx`, `Live<T>`, async tasks, input, accessibility, and desktop services.
- [Motion & Animation Guide](motion-and-animation.md) — Analytic springs, 4-edge layout morphing, enter/exit transitions, and choreography.
- [RuneKit Component Guide](runekit-components.md) — Themed controls, overlays, app shells, tables, trees, Markdown, Mermaid, and code diffs.
- [Rebuilding Apple UIs in Rune](rebuilding-apple-uis.md) — SwiftUI/AppKit/UIKit cheat sheet and blueprints for System Settings, frosted tab bars, Liquid Glass, Spotlight launchers, and custom macOS titlebars.
- [Visual Effects, Lighting & Custom GPU](effects-lighting-and-gpu.md) — `Compositor` GPU hooks, `RuneFX`, `RuneLight`, and `RuneKnobs`.
- [Testing, Profiling & Deployment](testing-and-deployment.md) — Headless snapshots, `--script` flows, unit tests, profiling, and shipping on every platform.
- [Products & Modules](products-and-modules.md) — Complete list of SwiftPM library products and package traits.
- [Standalone App Example](../examples/SparkStudio) — Real-world multi-panel SwiftPM desktop app consuming `Rune`, `RuneKit`, and `RuneMotion`.
