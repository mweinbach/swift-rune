# Core UI, Layout & Styling Guide

`Rune` is an immediate-style declarative UI library backed by a retained layout (`RuneTaffy`), animation (`RuneMotion`), accessibility, text-shaping, and GPU rendering engine. Each frame (or on state changes), your view function returns a pure `El<State>` tree, and Rune diffs it against the retained scene graph to animate changes, lay out elements, update OS accessibility nodes, and render instanced GPU primitives.

> Looking for state management, `Cx`/`Tx`, `Live<T>`, async `Machine`s, and desktop APIs? See [State, Events & Architecture](state-and-architecture.md).

---

## 1. Element Constructors

All UI trees are composed from `El<State>` values built with top-level constructors:

| Constructor | Description |
| :--- | :--- |
| `el()` | Generic container or styled rectangle |
| `col()` | Vertical flex container (`flex-direction: column`) |
| `row()` | Horizontal flex container (`flex-direction: row`) |
| `grid(columns:rows:)` | CSS Grid container |
| `text("...")` | Single-style text run with shaping, wrapping, and truncation |
| `liveText(...)` | Text driven by a `Live<String>` without rebuilding the full view tree |
| `rich(...)` | Multi-span rich text with mixed fonts, colors, links, and inline pills |
| `icon(svg, size:)` | Crisp vector `SVGIcon` rendered onto the glyph/vector pipeline |
| `image(...)` | Raster or animated image (`PNG`, `JPEG`, `WebP`, `GIF`, `APNG`) from `ImageCache` |
| `canvas(...)` | Custom vector drawing surface |
| `textInput(key: \State.edit)` | Full Unicode grapheme editor bound to a `TextEdit` property |
| `spacer()` | Flexible space-filling element (`grow(1)`) |
| `rule(thickness, color)` | Hairline horizontal separator |

### Adding Children

```swift
col()
    .gap(8)
    .child(text("Header"))
    .child(optionalSubtitleView) // `El<State>?` is safely ignored when nil
    .children(items.map { renderItem($0) })
```

### Keys & Retained Identity

Give a stable `.key("...")` to any element that is interactive, focusable, scrollable, animated, or part of a dynamic list:

```swift
for item in state.items {
    list = list.child(
        row()
            .key("item-\(item.id)")
            .animateLayout(Tok.Motion.SNAPPY)
            .child(text(item.title))
    )
}
```

Keys are scoped hierarchically by their ancestors, so `"knob"` inside `"switch-a"` does not collide with `"knob"` inside `"switch-b"`. Stable keys preserve:
- Keyboard focus and text caret/selection across view rebuilds
- Smooth velocity-preserving spring retargeting
- Enter/exit transitions and 4-edge layout morphing
- Scroll positions and OS accessibility node identity

---

## 2. Flexbox Layout

`Rune` uses `RuneTaffy` for CSS-compatible Flexbox, CSS Grid, Block, and Absolute positioning.

### Sizing

```swift
el()
    .size(200, 120)          // fixed width & height in logical points
    .square(32)              // width = 32, height = 32
    .w(240).h(44)            // explicit width / height
    .wFull().hFull()         // 100% width / height (shorthand: .sizeFull())
    .wFrac(0.5).hFrac(0.75)  // fractional percentage of parent
    .minW(120).maxW(600)     // min / max width constraints
    .minH(0).maxH(480)       // minH(0) is essential inside scrolling flex columns!
```

> **Flexbox Tip:** Inside a fixed-height `col()`, give flexible scroll containers `.grow(1).shrink(1).minH(0)` (and `.minW(0)` for truncating text inside a `row()`) so they shrink properly instead of overflowing their parent.

### Spacing (Padding, Margin & Gap)

```swift
col()
    .p(16)                   // all sides
    .px(12).py(8)            // horizontal / vertical
    .pt(4).pr(8).pb(12).pl(8)// individual edges
    .m(8)                    // margin all sides (also .mx, .my, .mt, .mr, .mb, .ml)
    .gap(12)                 // uniform spacing between children
```

### Alignment & Flex Distribution

```swift
row()
    .wFull()
    .itemsCenter()           // align-items: center (also .itemsStart(), .itemsEnd(), .itemsStretch())
    .justifyBetween()        // justify-content: space-between (also .justifyStart(), .justifyCenter(), .justifyEnd())
    .center()                // center along both axes
    .centerY()               // center vertically
    .child(text("Left").grow(1).minW(0).ellipsis())
    .child(text("Right").shrink(0))
```

---

## 3. CSS Grid Layout

Use `grid(...)` or `.gridTemplateColumns(...)` / `.gridTemplateRows(...)` for two-dimensional layouts such as dashboards, inspector forms, and bento grids:

```swift
grid(
    columns: [.fixed(140), .fr(1), .fr(2)],
    rows: [.auto, .fr(1)]
)
.wFull()
.hFull()
.gap(12)
.child(
    el()
        .gridColumn(.line(1), end: .span(3))
        .h(48)
        .bg(t.card)
        .rounded(Tok.Radius.md)
)
.child(
    el()
        .gridCell(column: 1)
        .bg(t.card)
        .rounded(Tok.Radius.md)
)
```

### Named Grid Areas

```swift
col()
    .gridTemplateAreas([
        ["header", "header"],
        ["sidebar", "content"],
        ["footer", "footer"],
    ])
    .gridTemplateColumns([.fixed(220), .fr(1)])
    .gridTemplateRows([.fixed(44), .fr(1), .fixed(28)])
    .child(headerView.gridArea("header"))
    .child(sidebarView.gridArea("sidebar"))
    .child(contentView.gridArea("content"))
    .child(statusBarView.gridArea("footer"))
```

Available grid modifiers:
- `.gridTemplateColumns([GridTrack])`, `.gridTemplateRows([GridTrack])`
- `.gridAutoColumns([GridTrack])`, `.gridAutoRows([GridTrack])`, `.gridAutoFlow(GridAutoFlow)`
- `.gridTemplateAreas([[String]])`
- `.gridCell(column:)`, `.gridColumn(_:end:row:)`, `.gridRow(_:end:)`, `.gridArea(_:)`

---

## 4. Positioning, Layering & Clipping

### Absolute Positioning & Pinning

```swift
// Explicit coordinates relative to parent top-left
el().absolute(x: 20, y: 12)

// Pin to parent edges (great for backdrops, scrims, and anchored overlays)
el()
    .pin(top: 0, right: 0, bottom: 0, left: 0)
    .z(100)
```

### Clipping & Soft Edge Fades

```swift
col()
    .rounded(12)
    .clip(true)                          // clip children to element bounds
    .clipRounded(12)                     // clip to rounded rect
    .clipFade(top: 12, bottom: 24)       // smooth alpha fade along clipped edges
    .clipFadeLinear(left: 16, right: 16) // linear gradient edge fade
```

### Sticky Headers

Headers inside a scroll container can stick to the top edge and reveal a drop shadow only while stuck using `.stuckShadow(...)`:

```swift
row()
    .key("section-header")
    .h(32)
    .bg(t.bg)
    .stuckShadow(Shadow(x: 0, y: 2, blur: 8, color: t.shadow))
    .child(text("Recent Files").font(Tok.Typography.section))
```

---

## 5. Colors, Design Tokens & Styling

### `Color` (Linear-Light sRGB + OKLCH)

`Color` stores linear-light RGBA (`Float` components in `0...1`) for physically accurate compositing and smooth perceptual interpolation in OKLab:

```swift
// Constructors
let fromHex   = Color.hex("#3b82f6")!         // #rgb, #rgba, #rrggbb, #rrggbbaa
let fromOklch = Color.oklch(0.66, 0.17, 256)  // perceptual Lightness, Chroma, Hue (deg)
let withAlpha = Color.oklcha(1.0, 0.0, 0.0, 0.08)
let fromSrgb  = Color.srgb(0.2, 0.4, 0.9, 1.0)
let fromBytes = Color.rgba8(59, 130, 246, 255)

// Operations
let translucent = fromHex.alpha(0.35)
let blended     = fromHex.mixOklab(with: .white, t: 0.25)
let ratio       = fromHex.contrastRatio(with: Color.hex("#111318")!) // WCAG 2.x ratio (1...21)
```

### Built-in Design Tokens (`Tok`)

```swift
let t = Tok.theme(dark: cx.systemDark)
let accent = Tok.accent(0, dark: cx.systemDark) // 0=blue, 1=purple, 2=pink, 3=orange, 4=green, 5=graphite
```

- **Colors (`ThemeTokens`)**: `bg`, `card`, `cardBorder`, `separator`, `text`, `textSecondary`, `controlTrack`, `controlOff`, `indicator`, `knob`, `knobShadow`, `hover`, `press`, `shadow`, `shadowSoft`, `edge`.
- **Spacing (`Tok.Space`)**: `xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (24), `xxl` (32).
- **Radii (`Tok.Radius`)**: `xs` (4), `sm` (6), `md` (8), `lg` (12), `xl` (16), `pill` (9999).
- **Typography (`Tok.Typography`)**: `body`, `label`, `section`, `title`, `monoCaption`.

### External JSON Themes (`JsonTheme`)

Load custom JSON themes supporting `"palette"` + `"light"`/`"dark"` + `"numbers"` maps:

```swift
let theme = try JsonTheme.fromJSON(jsonString, dark: cx.systemDark)
let bg = theme["bg"] ?? t.bg
let radius = theme.num("cardRadius") ?? Tok.Radius.lg
```

### Backgrounds, Gradients, Borders, Shadows & Transforms

```swift
el()
    .bg(t.card)
    .linearGradient(top: Color.white.alpha(0.08), bottom: .transparent)
    // or .radialGradient(inner: accent.alpha(0.25), outer: .transparent)
    .rounded(Tok.Radius.lg) // or .pill()
    .border(1.0, t.cardBorder)
    // or per-side borders: .borderSides(bottom: 1.0, color: t.separator)
    .shadow(Shadow(x: 0, y: 1, blur: 2, color: t.shadow))
    .shadow(Shadow(x: 0, y: 8, blur: 24, color: t.shadowSoft))
    // Inset shadow: Shadow(x: 0, y: 0, blur: 0, spread: 1, color: t.edge, inset: true)
    .opacity(0.95)
    .scale(1.02)
    .rotate(.pi * 0.25)
```

> **Hairline Borders:** On HiDPI displays, compute a 1-physical-pixel hairline with `let hair = 1.0 / max(1.0, cx.pixelScale)` and pass it to `.border(hair, t.cardBorder)`.

---

## 6. Typography, Rich Text & Icons

### Styled Text

```swift
text("Build succeeded")
    .font(TextStyle(size: 14, weight: 600).lh(20))
    .color(t.text)
    .ellipsis()    // single-line truncation with "..."
    .noWrap()      // prevent line wrapping
```

Shorthand helpers are also available directly on `text(...)`: `.size(18)`, `.semibold()`, `.mono()`, `.color(...)`.

### Vector Icons (`SVGIcon`)

Render crisp, resolution-independent vector icons at any scale:

```swift
let bolt = SVGIcon(
    viewBox: 16,
    paths: ["M9 1.5L3.5 9H8L7 14.5L12.5 7H8L9 1.5Z"],
    strokeWidth: 1.25
)

icon(bolt, size: 16).color(accent)
```

`RuneKit` also ships a curated `KitIcons` catalog (`check`, `close`, `search`, `copy`, `folder`, `file`, `chevronDown`, `chevronRight`, `plus`, `minus`, `lock`, `eye`, `eyeOff`, `info`, and more).

---

## 7. Vector Shapes & Paths (`Shape` & `Path`)

Build arbitrary filled polygons, Bézier curves, and animated stroke paths directly on any element with `.shape(...)`:

```swift
let wave = Path()
    .moveTo(0, 20)
    .cubicTo([20, 0], [40, 40], [60, 20])
    .lineTo(80, 20)

let waveShape = Shape()
    .viewBox(80, 40)
    .strokePath(wave, width: 2.5, cap: .round, color: accent)
    .drawn(state.progress) // animatable 0...1 path trim!

el()
    .size(160, 80)
    .shape(waveShape)
```

`Shape` supports:
- `.fill(_ points:, color:)` and `.fillPath(_ path:, color:)` (ear-clipped polygon triangulation)
- `.stroke(_ points:, width:, color:)`, `.strokePath(_ path:, width:, cap:, color:)`, `.line(_ a:, _ b:, width:, cap:, color:)`
- `.viewBox(_ width:, _ height:)` for automatic scaling to element bounds
- `.drawn(_ t:)` and `.trimmed(start:end:)` for progressive stroke reveal animations

---

## 8. Images (`ImageCache`)

Load images asynchronously from memory (`Data`) or URLs without blocking the UI thread:

```swift
// From encoded bytes (PNG, JPEG, WebP, GIF, APNG)
let handle = ImageCache.load(pngData)

// From a relative URL (web) or file path
let logo = ImageCache.url("assets/logo.webp", sizePt: 32, scale: cx.pixelScale)

if let pixels = handle.pixels {
    image(pixels).size(64, 64).rounded(8)
}
```

Rune automatically triggers a repaint when decoding finishes and supports animated GIF and WebP/APNG playback.

---

## 9. Scrolling & Virtualized Lists

### Standard Scroll Containers

```swift
col()
    .key("feed")
    .gap(8)
    .children(rows)
    .scroll(stickBottom: true)      // optional auto-stick to bottom (e.g. chat/logs)
    .scrollEdgeFade(16)             // smooth alpha fade at scrolling edges
    .onScroll { state, pos, _ in
        state.scrollY = pos.y
    }
    .grow(1)
    .shrink(1)
    .minH(0)
```

### Virtualizing Large Lists (`virtualList` / `virtualRows`)

When rendering thousands of rows, avoid building off-screen `El<State>` subtrees by using `virtualList` / `virtualRows` (or `RuneKit`'s virtualized `Table` and `TreeView`, benchmarked at 100,000+ rows):

- Keep a `VirtualListState` (or `RuneKit` table/tree state) across frames.
- Only visible rows plus a small overscan buffer are materialized, laid out, and projected into accessibility.
- Measured heights are cached automatically (`recordMeasuredHeight(_:forKey:)`), and scroll anchoring preserves position when items above the viewport grow or reorder (`.scrollAnchor(true)`).
