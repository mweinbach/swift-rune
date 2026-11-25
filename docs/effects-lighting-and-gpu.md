# Visual Effects, Lighting & Custom GPU Guide

Beyond standard UI primitives, `swift-rune` lets you author custom native GPU passes inside the UI painter order (`Compositor`), layer procedural shader effects (`RuneFX`), simulate real-time 2D/2.5D lighting and refractive glass (`RuneLight`), and live-tune parameters at runtime (`RuneKnobs`).

---

## 1. Custom GPU Passes (`Compositor`)

Rune lets you interleave custom **Metal** (Apple), **OpenGL 3.3 / GLES 3** (Windows, Linux, Android), or **WebGPU / WebGL 2** (Browser) rendering directly inside your declarative UI tree—so UI cards can paint *behind* and *in front of* your custom GPU content in exact painter order.

### Step 1: Mark an Effect Slot in Your View

```swift
el()
    .key("shader-viewport")
    .wFull()
    .h(320)
    .rounded(16)
    .effect("hero-shader")       // invokes your compositor hook at this painter slot
    .effectBackdrop(true)        // optional: snapshot earlier UI content as a backdrop texture
```

### Step 2: Implement `Compositor`

```swift
final class MyCompositor: Compositor {
    typealias State = MyState

    var isAnimating: Bool { true }

    func render(frame: CompositorFrame<MyState>) {
        // Draws Rune's UI and calls your closure for each visible `.effect(mark)` slot
        try? frame.drawUI { pass in
            // `pass` provides:
            // - pass.mark (e.g. "hero-shader")
            // - device-pixel rect & clip bounds
            // - Metal render command encoder (Apple) or OpenGL FBO + proc resolver (Windows/Linux/Android)
            // - optional backdrop texture when `.effectBackdrop(true)` is set
        }
    }
}
```

### Step 3: Attach to `App<State>`

```swift
let app = App<MyState>(title: "GPU Demo", size: Vec2(900, 600), state: MyState(), view: myView)
    .compositor(MyCompositor())

try RuneApp.run(app)
```

> **Resource Lifetime:** The render target and optional backdrop texture passed into the effect hook are borrowed for the duration of that callback—draw synchronously and do not retain them across frames.

On the **Web**, supply `drawEffect(pass)` (WebGL 2) or `drawGPUEffect(pass)` (WebGPU) in your `mountRuneBrowser` options to handle the exact same `.effect(mark)` slots in the browser.

---

## 2. Special Effects (`RuneFX`)

Add `.product(name: "RuneFX", package: "swift-rune")` and `import RuneFX` for ready-made GPU shaders (Metal & OpenGL) plus a deterministic CPU reference renderer (`RuneFXCPU`).

### Effect Families (`Fx` & `FxLayer`)

`RuneFX` organizes effects into composable `FxLayer` entries placed relative to UI slots (`FxSlot`, `Place`, `FxBlend`):

- **Glow & Bloom** (`GlowParams`, `GlowStyle`) — Soft outer/inner glows and thresholded bloom
- **Pulses & Ripples** (`PulseParams`, `PulseStyle`) — Expanding energy rings and shockwaves
- **Electricity & Arcs** (`ElectricParams`, `ElectricStyle`) — Procedural animated lightning/plasma arcs
- **Procedural Fire & Embers** (`FireParams`, `FireStyle`, `FireSimPlan`) — Ping-pong fluid/heat simulation for stylized flames
- **Optical Distortion & Lens** (`DistortParams`, `LensParams`) — Refraction lenses and surface ripples
- **Motion Blur** (`MotionBlurParams`, `MotionSamples`, `Pose`) — Velocity-driven directional/radial blur
- **Procedural Fills** (`FillParams`, `FillStyle`):
  - `LiquidMetalParams` — Animated metallic chrome ripples
  - `MeshGradientParams` — Multi-stop organic mesh gradients
  - `FlutedGlassParams` — Ribbed/fluted optical glass distortion
  - `GrainGradientParams` — Film-grain textured gradients
  - `DitherParams`, `HalftoneParams`, `MetaballParams`, `SwirlParams`, `VoronoiParams`, `WaveParams`
- **Post-Processing**: Chromatic aberration, vignette, film grain, and `OneShots<T>` for triggered burst effects

### Try the Built-in FX Examples

```bash
swift run rune-fx-first-glow
swift run rune-fx-gallery --still glow --snap glow.png
swift run rune-background
```

---

## 3. Real-Time 2D/2.5D Lighting & Refractive Glass (`RuneLight`)

Add `.product(name: "RuneLight", package: "swift-rune")` and `import RuneLight` for physically inspired UI lighting and glass surfaces running on Metal and OpenGL.

### Building a `LightScene`

Describe scene geometry (`Prim`) and light sources (`Light`) in logical UI coordinates:

```swift
import RuneLight

// A raised bevelled UI card that casts soft SDF shadows and catches specular highlights
let cardPrim = Prim(rect: SIMD4(80, 80, 320, 200))
    .radius(16)
    .raised(12)
    .bevel(width: 8, height: 3)
    .gloss(0.65, roughness: 0.25)
    .albedo(SIMD3(0.18, 0.20, 0.24))

// A warm point light with soft shadows and volumetric shafts
let keyLight = Light(position: SIMD3(240, 60, 120))
    .color(SIMD3(1.0, 0.86, 0.72))
    .intensity(1.4)
    .radius(24)
    .range(520)
    .softness(0.6)
    .shafts(0.25)
```

`RuneLight` also supports:
- **Spot & Directional Lights** (`.spot(axis:halfAngle:)`)
- **Emissive Surfaces & Radiance-Cascade Global Illumination** (`.emissive(_:)`, `.giHint()`, `GIParams`)
- **Refractive Glass (`Glass`, `GlassSettings`, `GlassLight`)**:
  ```swift
  let lens = Glass(rect: SIMD4(120, 120, 260, 140), radius: 24)
      .thickness(18)
      .bevel(12)
      .ior(1.48)          // index of refraction
      .dispersion(0.15)   // subtle chromatic dispersion
      .frost(0.2)         // frosted backdrop blur
      .rimGlow(0.35)
      // Smooth boolean union for liquid-glass morphing between two shapes:
      .union(rect: SIMD4(320, 140, 100, 100), radius: 50, k: 24, morph: 1.0)
  ```

### Try the Built-in Lighting Examples

```bash
swift run rune-light-live --scene chat
swift run rune-glass-panel
swift run rune-light-demos
swift run rune-site-scenes
```

---

## 4. Live Parameter Tuning (`RuneKnobs`)

Add `.product(name: "RuneKnobs", package: "swift-rune")` and `import RuneKnobs` to expose numeric sliders, toggles, colors, and presets in a live in-app tuning panel (toggled with `⌘⇧K` / `Ctrl+Shift+K`) without recompiling:

- Define parameters via `Knob`, organize them into `KnobGroup`, and register presets (`KnobPreset` / `SavedKnobPreset`).
- Great for dialing in spring physics, spacing tokens, `RuneFX` shader uniforms, and `RuneLight` materials interactively while watching your UI respond in real time.

```bash
swift run rune-knobs
```
