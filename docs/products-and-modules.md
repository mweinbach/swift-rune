# SwiftPM Products & Modules

`swift-rune` is structured as a modular SwiftPM package so you only link the libraries your app needs.

## Library Products

Add any of the following products to your target's `dependencies` in `Package.swift`:

```swift
.product(name: "<ProductName>", package: "swift-rune")
```

### Core UI & Components

| Product | Description | Typical Use |
| :--- | :--- | :--- |
| **`Rune`** | Declarative `El<State>` view tree, Flexbox/Grid layout, text shaping & editing, vector shapes, GPU renderers (Metal / OpenGL / GLES / WebGPU / WebGL 2), CPU reference renderer, accessibility, clipboard, file dialogs, native/web app hosts, and `HeadlessRunner`. Re-exports `RuneMotion` and `RuneRef`. | Required for every Rune UI app. |
| **`RuneKit`** | WCAG-contrast-checked UI component kit (`Kit.fromPalette`): buttons, inputs, switches, sliders, dialogs, menus, popovers, toasts, tabs, sidebars, virtualized tables & trees, Markdown, syntax highlighting, Mermaid diagrams, and diff views. | Recommended for building full apps quickly. |
| **`RuneMotion`** | Standalone analytic spring physics (`Spring`), easing curves, keyframes, `AnimationStore`, 4-edge layout morphing, enter/exit transitions, choreography, and gesture velocity tracking. | Standalone motion math (also re-exported by `Rune`). |
| **`OpenCodeTheme`** | Ready-made OpenCode light/dark theme definitions, SVG icon sets, and themed helpers for `Rune` + `RuneKit`. | Instant polished developer-tool styling. |

### Visual Effects, Shaders & Rich Content

| Product | Description | Typical Use |
| :--- | :--- | :--- |
| **`RuneFX`** | Special-effects layers and Metal/OpenGL shaders: glow/bloom, pulses, electricity, procedural fire/embers (`FireSim`), motion blur, ripple distortion, chromatic aberration, vignette, and grain. | Rich visual polish, creative tools, games/demos. |
| **`RuneLight`** | Real-time 2D/2.5D lighting engine with Metal/OpenGL shaders: SDF soft shadows, bevel normals, point/directional/spot lights, god rays, radiance-cascade GI, and refractive glass. | Glassmorphism, physical lighting, interactive scenes. |
| **`RuneHighlights`** | Zero-dependency syntax highlighter for 100+ programming languages with filename, shebang, and content detection. | Code editors, logs, docs viewers (also used by `RuneKit`). |
| **`RuneMermaid`** | Native Mermaid diagram parser, Sugiyama layout engine, connector router, and vector renderer covering 17 diagram families. | Technical docs, architecture viewers (also used by `RuneKit`). |

### Desktop, Platform & App Infrastructure

| Product | Description | Typical Use |
| :--- | :--- | :--- |
| **`RuneNotify`** | Cross-platform native system notifications (Apple UserNotifications, Windows WinRT toasts, Linux freedesktop D-Bus) plus a deterministic test backend. | Desktop alerts and inline notification actions. |
| **`RuneMac`** | macOS `NSWindow` frame autosave/restoration, multi-display clamping, fullscreen, and relaunch helpers. | Polishing native macOS desktop apps. |
| **`RuneI18n`** | BCP-47 locale parsing, RTL detection, locale negotiation, CLDR pluralization, number/list formatting, `{{template}}` interpolation, and JSON catalogs. | Internationalizing multi-language UIs. |
| **`RuneKnobs`** | Live runtime parameter registry (`KnobGroup`, `KnobRegistry`) and interactive `⌘⇧K` tuning overlay. | Live-tuning animations, shaders, and layout constants. |
| **`RuneLuau`** | Pure-Swift sandboxed Luau compiler and bytecode VM with `@rune/signal` and `@rune/ui` reactive bindings. | Plugin systems and live-scriptable UI panels. |
| **`RunePerf`** | Bounded performance recorder, CPU/RSS telemetry, scoped spans/histograms, and Chrome Trace Event JSON export. | Frame pacing and performance diagnostics. |

### Low-Level & Testing Libraries

| Product | Description | Typical Use |
| :--- | :--- | :--- |
| **`RuneTaffy`** | Standalone CSS Flexbox, CSS Grid, Block, and Absolute layout engine (`LayoutEngine`, `TaffyStyle`). | Custom layout engines without the full UI runtime. |
| **`RuneRef`** | Portable CPU reference rasterizer (`RuneRef.render`), PNG encode/decode, and pixel-level `RuneRef.diff`. | Visual regression tests and headless snapshots (also re-exported by `Rune`). |
| **`RuneRegister`** | Thread-safe distributed registry for decentralized scene, story, and knob registration. | Modular galleries and plugin registries. |
| **`RuneStaging`** | Internal staging utilities for experimental features. | Internal/advanced tooling. |

---

## Package Traits

`swift-rune` defines two SwiftPM package traits:

| Trait | Default | Description |
| :--- | :--- | :--- |
| **`DesktopMedia`** | Enabled | Enables native audio/video playback and microphone recording on Windows (Media Foundation / WASAPI) and Linux (GStreamer). Disable (`traits: []` or `--disable-default-traits`) for UI-only builds without media libraries. |
| **`BaselineTaffy`** | Disabled | Enables the reference `TaffyTree` backend for layout parity benchmarking. |

---

## Platform Support Matrix

| Platform | Minimum OS | Graphics Backend | Text Shaping | Accessibility |
| :--- | :--- | :--- | :--- | :--- |
| **macOS** | macOS 14+ | Metal | Core Text | NSAccessibility |
| **iOS / iPadOS** | iOS 17+ | Metal | Core Text | UIAccessibility |
| **tvOS / visionOS** | tvOS 17+ / visionOS 1+ | Metal | Core Text | UIAccessibility |
| **Windows** | Windows 10/11 | OpenGL 3.3 Core (WGL) | DirectWrite | UI Automation |
| **Linux** | Wayland or X11 | OpenGL 3.3 Core (EGL/GLX) | Pango / Cairo | AT-SPI |
| **Android** | API 24+ | OpenGL ES 3 (EGL) | Android Font / Outline Bridge | AccessibilityNodeProvider |
| **WebAssembly** | `wasm32-unknown-wasip1` | WebGPU / WebGL 2 / CPU | Browser `rune_text` Bridge | DOM / ARIA |
