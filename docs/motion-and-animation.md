# Motion & Animation Guide (`RuneMotion`)

`RuneMotion` is Rune's analytic animation runtime (automatically re-exported whenever you `import Rune`). Instead of fixed-timestep approximations that drift or lose momentum on interruption, `RuneMotion` evaluates springs, cubic Béziers, decay curves, and keyframe tracks **analytically** at any timestamp—giving you velocity-preserving retargeting, smooth premultiplied OKLab color transitions, 4-edge layout morphing, and deterministic headless frame capture.

---

## 1. Springs & Motion Tokens

Define springs in perceptual `(duration, bounce)` coordinates rather than raw stiffness/damping constants:

```swift
import Rune // re-exports RuneMotion

let crisp  = Spring(duration: 0.25, bounce: 0.0)   // critically damped, zero overshoot
let lively = Spring(duration: 0.40, bounce: 0.25)  // gentle playful overshoot
let slow   = crisp.scaledDuration(2.0)             // 2x slower
let exact  = crisp.withDuration(0.35)
```

### Built-in Presets (`Tok.Motion` / `MotionTokens`)

| Preset | Character | Typical Use |
| :--- | :--- | :--- |
| `Tok.Motion.INSTANT` | Zero-duration snap | Immediate state changes |
| `Tok.Motion.SNAPPY` | Fast, crisp response | Switches, toggles, hover highlights, small controls |
| `Tok.Motion.DEFAULT` | Balanced everyday spring | General UI transitions |
| `Tok.Motion.CALM` | Gentle, unhurried settle | Large panels, drawers, theme/color shifts |
| `Tok.Motion.MORPH` | Smooth geometry morph | Shared-element & card expansions |
| `Tok.Motion.POP` | Subtle energetic bounce | Popovers, badges, checkmarks |
| `Tok.Motion.LEAD` | `Spring(duration: 0.2, bounce: 0.0)` | Leading edge of traveling indicators |

### Asymmetric Springs (`SpringPair`)

Use `SpringPair` when an enter animation should feel snappier or bouncier than its exit:

```swift
let pair = SpringPair(
    enter: Tok.Motion.POP,
    exit: Tok.Motion.SNAPPY
)
```

---

## 2. Animating Visual Properties (`.animate`)

Attach `.animate(...)` to any **keyed** element to smoothly interpolate background color, border color, opacity, scale, rotation, corner radius, and blur whenever its target values change:

```swift
el()
    .key("pill")
    .bg(state.active ? accent : t.controlOff)
    .opacity(state.active ? 1.0 : 0.7)
    .scale(state.active ? 1.0 : 0.96)
    .animate(Tok.Motion.SNAPPY)
```

- Colors automatically interpolate in **premultiplied OKLab**, avoiding muddy gray midpoints and alpha fringes.
- Retargeting mid-flight preserves the element's current velocity—rapidly clicking a toggle never jumps or restarts from zero.

---

## 3. 4-Edge Layout Morphing (`.animateLayout`)

Attach `.animateLayout(...)` to animate position and size changes (`x`, `y`, `width`, `height`) independently across all four edges:

```swift
// Animated switch knob sliding inside its track
el()
    .key("knob")
    .size(18, 18)
    .pill()
    .bg(t.knob)
    .absolute(x: state.on ? 20 : 2, y: 2)
    .animateLayout(Tok.Motion.SNAPPY)

// Animated progress bar width
el()
    .key("bar")
    .w(progressWidth)
    .h(4)
    .rounded(2)
    .bg(accent)
    .animateLayout(LayoutAnim(spring: Spring(duration: 0.4, bounce: 0.2)))
```

Because layout animations track elements by **key**, you can also move a keyed element (such as an active tab indicator or a card moving between containers) and Rune smoothly morphs its bounding rect from the old layout box to the new one. See `Sources/Examples/RuneMatched` and `Sources/Examples/RuneMotionBento` for matched-geometry examples.

---

## 4. Enter & Exit Transitions (`.transition`)

When a keyed element is conditionally inserted into or removed from your view tree, `.transition(...)` keeps the exiting element alive in the scene until its exit animation finishes:

```swift
if state.showToast {
    row()
        .key("save-toast")
        .px(14).py(10)
        .rounded(Tok.Radius.md)
        .bg(t.card)
        .transition(
            Transition.scale(0.94)
                .combined(with: .opacity)
                .spring(Tok.Motion.POP)
        )
        .child(text("Changes saved").color(t.text))
}
```

### Useful `Transition` Modifiers

- `.combined(with:)` — Combine multiple effects (e.g. scale + opacity + slide/blur).
- `.spring(_:)` — Use a single spring for both enter and exit.
- `.springs(_:)` — Supply an asymmetric `SpringPair`.
- `.holdLayout()` — Keep the element's layout space reserved while animating out so siblings don't jump prematurely.
- `.kitRules(small:)` — Applies `RuneKit`'s refined micro-motion rules (e.g. subtle exit timing for icons/tooltips).

---

## 5. Easing Curves, Keyframes & Choreography

When you need standalone motion math or multi-step staged animations outside simple view modifiers, use `RuneMotion` directly:

### `CubicBezier` & `Easing`

```swift
let easeOut = CubicBezier(0.16, 1.0, 0.3, 1.0)
let y = easeOut.sample(0.5)
let (val, slope) = easeOut.evalWithSlope(0.5)
```

### Staggers (`stagger`)

Compute per-item stagger delays for cascading lists and grids:

```swift
for (i, item) in items.enumerated() {
    let delay = stagger(index: i, count: items.count, gap: 0.035, from: .start)
    // Use delay with Choreography / KeyframeTrack / custom curves
}
```

### Multi-Step `Choreography` & `ChoreographyPhaseAnimator`

Coordinate sequenced, overlapping, or hold-and-advance animations with `Choreography`, `Cue`, `When`, and `ChoreographyPhaseAnimator`:

- `Cue` lets you chain steps via `.after(seconds)` and `.notBefore(t)`.
- `ChoreographyPhaseAnimator` lets you define repeating or `.once()` multi-phase loops with `.phase { ops in ... }`, `.advanceOn(when)`, and `.hold(seconds)`.

### Gesture Physics (`VelocityTracker`)

Track pointer drag velocities across frames to hand off directly into spring retargeting or inertial `Decay` scrolling/flinging.

---

## 6. Transaction Overrides & Reduced Motion

### Overriding Motion in Callbacks

Inside any event handler with `Tx`:

```swift
.onClick { state, tx in
    state.activeTab = tabID
    if state.jumpInstantly {
        tx.instant()                 // skip springs for this state update
    } else {
        tx.motion(Tok.Motion.MORPH)  // custom spring for this commit
    }
}
```

### Respecting Reduced Motion

Rune automatically reads the host OS "Reduce Motion" setting (`cx.reducedMotion`) and simplifies spring/transform animations accordingly. You can also expose an in-app toggle:

```swift
func myView(_ s: AppState, _ cx: inout Cx<AppState>) -> El<AppState> {
    cx.reducedMotion(s.reduceMotion)
    cx.timeScale(s.animationSpeed) // e.g. 0.5x..2.0x
    ...
}
```

And in headless visual testing, pass `--reduced-motion` or `--at <seconds>` to inspect any exact instant of an animation deterministically.
