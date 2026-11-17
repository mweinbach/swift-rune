import Foundation
#if os(Android)
import Android
#endif
import RuneMotion
import RuneRef

/// Separates help text from each of its `El.helpKeys` keycaps (`crates/rune/src/el/help.rs`).
internal let runeHelpKeySeparator: Character = "\u{1f}"

/// Separates help rows in `El.helpRow` (`crates/rune/src/el/help.rs`).
internal let runeHelpRowSeparator: Character = "\u{1e}"

/// Converts internal help markers into human/a11y plain text:
/// keycaps separated by a space, rows separated by a newline.
public func runeHelpWords(_ help: String) -> String {
    guard help.contains(runeHelpKeySeparator) || help.contains(runeHelpRowSeparator) else {
        return help
    }
    return help
        .replacingOccurrences(of: String(runeHelpKeySeparator), with: " ")
        .replacingOccurrences(of: String(runeHelpRowSeparator), with: "\n")
}

/// Visual and timing configuration for `El.help` tooltips (`rune::HelpLook`).
public struct HelpLook: Sendable, Equatable {
    public struct Ring: Sendable, Equatable {
        public var width: Float
        public var color: Color

        public init(width: Float, color: Color) {
            self.width = width
            self.color = color
        }
    }

    public struct KeyCap: Sendable, Equatable {
        public var fill: Color
        public var ink: Color
        public var font: TextStyle
        public var height: Float
        public var padX: Float
        public var radius: Float
        public var gap: Float
        public var lead: Float
        public var upper: Bool

        public init(
            fill: Color,
            ink: Color,
            font: TextStyle,
            height: Float = 16.0,
            padX: Float = 4.0,
            radius: Float = 3.0,
            gap: Float = 2.0,
            lead: Float = 6.0,
            upper: Bool = false
        ) {
            self.fill = fill
            self.ink = ink
            self.font = font
            self.height = height
            self.padX = padX
            self.radius = radius
            self.gap = gap
            self.lead = lead
            self.upper = upper
        }
    }

    public var fill: Color
    public var ink: Color
    public var ringSpec: Ring?
    public var radius: Float
    public var paddingX: Float
    public var paddingY: Float
    public var font: TextStyle
    public var maxW: Float?
    public var gapBelow: Float
    public var gapOver: Float
    public var margin: Float
    public var delaySeconds: Double?
    public var skipSeconds: Double
    public var fadeEnter: Double
    public var fadeExit: Double
    public var fadeScale: Float
    public var shadowLayers: [Shadow]
    public var key: KeyCap
    public var rowGap: Float

    public static let maxShadows = 4

    public static func system(dark: Bool) -> HelpLook {
        @inline(__always) func grey(_ v: Float) -> Color {
            Color(r: v, g: v, b: v, a: 1.0)
        }
        let fill: Color
        let ink: Color
        let edge: Color
        if dark {
            fill = grey(0.17)
            ink = grey(0.93)
            edge = Color.white.alpha(0.14)
        } else {
            fill = grey(0.98)
            ink = grey(0.11)
            edge = Color.black.alpha(0.16)
        }
        return HelpLook(
            fill: fill,
            ink: ink,
            ringSpec: Ring(width: 1.0, color: edge),
            radius: 5.0,
            paddingX: 7.0,
            paddingY: 4.0,
            font: TextStyle(size: 12.0, weight: 400.0, lineHeight: 16.0),
            maxW: 300.0,
            gapBelow: 6.0,
            gapOver: 4.0,
            margin: 4.0,
            delaySeconds: nil,
            skipSeconds: 0.0,
            fadeEnter: 0.0,
            fadeExit: 0.0,
            fadeScale: 1.0,
            shadowLayers: [],
            key: KeyCap(
                fill: ink.alpha(0.08),
                ink: ink.alpha(0.7),
                font: TextStyle(size: 11.0, weight: 500.0, lineHeight: 11.0),
                height: 16.0,
                padX: 4.0,
                radius: 3.0,
                gap: 2.0,
                lead: 6.0,
                upper: false
            ),
            rowGap: 4.0
        )
    }

    public func rowGap(_ gap: Float) -> HelpLook {
        var copy = self
        copy.rowGap = gap.isFinite ? max(0.0, gap) : 0.0
        return copy
    }

    public func keycaps(fill: Color, ink: Color, font: TextStyle, upper: Bool) -> HelpLook {
        var copy = self
        copy.key.fill = fill
        copy.key.ink = ink
        copy.key.font = font
        copy.key.upper = upper
        return copy
    }

    public func keycapShape(height: Float, padX: Float, radius: Float, gap: Float, lead: Float) -> HelpLook {
        var copy = self
        copy.key.height = max(0.0, height)
        copy.key.padX = max(0.0, padX)
        copy.key.radius = max(0.0, radius)
        copy.key.gap = max(0.0, gap)
        copy.key.lead = max(0.0, lead)
        return copy
    }

    public func fill(_ color: Color) -> HelpLook {
        var copy = self
        copy.fill = color
        return copy
    }

    public func ink(_ color: Color) -> HelpLook {
        var copy = self
        copy.ink = color
        return copy
    }

    public func ring(_ width: Float, _ color: Color) -> HelpLook {
        var copy = self
        copy.ringSpec = (width > 0.0 && width.isFinite) ? Ring(width: width, color: color) : nil
        return copy
    }

    public func radius(_ r: Float) -> HelpLook {
        var copy = self
        copy.radius = max(0.0, r)
        return copy
    }

    public func padding(_ x: Float, _ y: Float) -> HelpLook {
        var copy = self
        copy.paddingX = max(0.0, x)
        copy.paddingY = max(0.0, y)
        return copy
    }

    public func font(_ style: TextStyle) -> HelpLook {
        var copy = self
        copy.font = style
        return copy
    }

    public func maxWidth(_ w: Float?) -> HelpLook {
        var copy = self
        copy.maxW = w.flatMap { $0 > 0.0 ? $0 : nil }
        return copy
    }

    public func gap(_ g: Float) -> HelpLook {
        var copy = self
        copy.gapBelow = g
        copy.gapOver = g
        return copy
    }

    public func margin(_ m: Float) -> HelpLook {
        var copy = self
        copy.margin = max(0.0, m)
        return copy
    }

    public func delay(_ secs: Double) -> HelpLook {
        var copy = self
        copy.delaySeconds = max(0.0, secs)
        return copy
    }

    public func skipDelay(_ secs: Double) -> HelpLook {
        var copy = self
        copy.skipSeconds = max(0.0, secs)
        return copy
    }

    public func fade(enter: Double, exit: Double, scale: Float = 1.0) -> HelpLook {
        var copy = self
        copy.fadeEnter = max(0.0, enter)
        copy.fadeExit = max(0.0, exit)
        copy.fadeScale = scale.isFinite ? max(0.0, min(1.0, scale)) : 1.0
        return copy
    }

    public func shadows(_ layers: [Shadow]) -> HelpLook {
        var copy = self
        copy.shadowLayers = Array(layers.filter { !$0.inset }.prefix(Self.maxShadows))
        return copy
    }
}

// MARK: - Tooltip State Machine & Hit Geometry

internal struct HelpHitRecord: Sendable {
    var path: String
    var key: String?
    /// Visible clipped rect in window points: `[x0, y0, x1, y1]`.
    var rect: SIMD4<Float>
    /// Number of interactive hits already recorded before this help element painted.
    var seq: Int
    var text: String
    var side: Side?
    var linkIndex: Int?
}

internal struct HelpInteractiveHitRecord: Sendable {
    var path: String
    /// Bounds in window points: `[x0, y0, x1, y1]`.
    var rect: SIMD4<Float>
}

internal struct HelpTarget: Equatable, Sendable {
    var path: String
    var link: Int?
}

internal enum HelpTipState: Equatable, Sendable {
    case idle
    case warm(until: Double)
    case waiting(target: HelpTarget, since: Double)
    case open(target: HelpTarget, since: Double)
    case suppressed(target: HelpTarget)

    var target: HelpTarget? {
        switch self {
        case .waiting(let target, _), .open(let target, _), .suppressed(let target):
            return target
        case .idle, .warm:
            return nil
        }
    }
}

internal enum HelpOver: Equatable, Sendable {
    case away
    case nothing
    case help(HelpTarget)
    case covered(HelpTarget)
}

internal enum HelpStepEvent: Equatable, Sendable {
    case frame(over: HelpOver, now: Double)
    case dismiss
}

internal enum HelpEffect: Equatable, Sendable {
    case wakeAt(Double)
    case fadeOut
}

internal struct HelpDrawnTip: Sendable {
    var text: String
    /// Anchor box in window points `[x0, y0, x1, y1]`.
    var anchor: SIMD4<Float>
    var side: Side?
    var alpha: Float
    var scale: Float
}

internal struct HelpRuntimeState: Sendable {
    var hits: [HelpHitRecord] = []
    var interactiveHits: [HelpInteractiveHitRecord] = []
    var tipState: HelpTipState = .idle
    var currentTip: (text: String, rect: SIMD4<Float>)? = nil
    var drawn: HelpDrawnTip? = nil
    var leaving: (tip: HelpDrawnTip, closedAt: Double)? = nil
    var native: Bool = false
    var regions: [(rect: SIMD4<Float>, text: String)] = []
}

internal func stepHelpTip(
    _ tip: inout HelpTipState,
    event: HelpStepEvent,
    openDelay: Double,
    skipDelay: Double
) -> [HelpEffect] {
    func suppress(_ t: inout HelpTipState) -> [HelpEffect] {
        switch t {
        case .open(let target, _):
            t = .suppressed(target: target)
            return [.fadeOut]
        case .waiting(let target, _), .suppressed(let target):
            t = .suppressed(target: target)
            return []
        case .idle, .warm:
            return []
        }
    }

    func leave(_ t: inout HelpTipState, at: HelpTarget?, now: Double) -> [HelpEffect] {
        let wasOpen: Bool
        let currentlyWarm: Bool
        switch t {
        case .open:
            wasOpen = true
            currentlyWarm = skipDelay > 0.0
        case .warm(let until):
            wasOpen = false
            currentlyWarm = now <= until
        default:
            wasOpen = false
            currentlyWarm = false
        }
        var effects: [HelpEffect] = wasOpen ? [.fadeOut] : []
        if let target = at {
            if currentlyWarm {
                t = .open(target: target, since: now)
            } else {
                effects.append(.wakeAt(now + openDelay))
                t = .waiting(target: target, since: now)
            }
        } else if wasOpen && skipDelay > 0.0 {
            t = .warm(until: now + skipDelay)
        } else if !currentlyWarm {
            t = .idle
        }
        return effects
    }

    switch event {
    case .dismiss:
        return suppress(&tip)
    case .frame(let over, let now):
        let effects: [HelpEffect]
        switch over {
        case .away where { if case .suppressed = tip { return true }; return false }():
            effects = []
        case .covered(let at) where tip.target == at:
            effects = suppress(&tip)
        case .help(let at) where tip.target == at:
            effects = []
        case .help(let at):
            effects = leave(&tip, at: at, now: now)
        case .away, .nothing, .covered:
            effects = leave(&tip, at: nil, now: now)
        }

        switch tip {
        case .warm(let until) where now > until:
            tip = .idle
        case .waiting(let target, let since) where now + 1e-6 >= since + openDelay:
            tip = .open(target: target, since: now)
        default:
            break
        }
        return effects
    }
}

@inline(__always)
internal func helpRectContains(_ rect: SIMD4<Float>, point: Vec2) -> Bool {
    point.x >= rect.x && point.x < rect.z && point.y >= rect.y && point.y < rect.w
}

@inline(__always)
internal func helpRectOverlaps(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
    a.x < b.z && b.x < a.z && a.y < b.w && b.y < a.w
}

/// Returns `a` minus `b` (both `[x0, y0, x1, y1]`) as up to four non-empty rectangles:
/// bands above and below `b`, then strips left and right of `b`.
internal func helpRectSubtract(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> [SIMD4<Float>] {
    guard helpRectOverlaps(a, b) else { return [a] }
    let y0 = max(b.y, a.y)
    let y1 = min(b.w, a.w)
    let candidates = [
        SIMD4<Float>(a.x, a.y, a.z, y0),
        SIMD4<Float>(a.x, y1, a.z, a.w),
        SIMD4<Float>(a.x, y0, max(b.x, a.x), y1),
        SIMD4<Float>(min(b.z, a.z), y0, a.z, y1),
    ]
    return candidates.filter { $0.z > $0.x && $0.w > $0.y }
}

private struct HelpTipRow {
    var hasWords: Bool
    var shaped: ShapedText?
    var tw: Float
    var th: Float
    var ch: Float
    var caps: [(shaped: ShapedText, width: Float)]
    var keysW: Float
}

/// Measures, positions, and draws `tip` in `look`, returning `[x, y, w, h]` in window points.
internal func drawHelpTooltip<State>(
    _ tip: HelpDrawnTip,
    look: HelpLook,
    runtime: Runtime<State>,
    primitives: inout [Primitive],
    recordGlyphPage: (Int, UInt16) -> Void
) -> SIMD4<Float> {
    let viewport = runtime.viewport
    let pixelScale = runtime.pixelScale
    let srgbBlend = runtime.srgbBlend
    let textSystem = runtime.textSystem
    let e = tip.anchor
    let s = max(1.0, pixelScale)
    let keyLook = look.key
    let padX = look.paddingX
    let padY = look.paddingY
    let vw = viewport.x
    let vh = viewport.y
    let margin = look.margin
    let wrap = max(1.0, look.maxW ?? (vw - 2.0 * margin - 2.0 * padX))

    var rows: [HelpTipRow] = []
    let rawRows = tip.text.split(separator: runeHelpRowSeparator, omittingEmptySubsequences: false)
    for rawRow in rawRows {
        let parts = rawRow.split(separator: runeHelpKeySeparator, omittingEmptySubsequences: false)
        let words = parts.first.map(String.init) ?? ""
        var caps: [(ShapedText, Float)] = []
        if parts.count > 1 {
            for part in parts.dropFirst() {
                let rawKey = String(part)
                let label = keyLook.upper ? rawKey.uppercased() : rawKey
                let shapedKey = textSystem.shape(
                    text: label,
                    spans: nil,
                    style: keyLook.font,
                    maxWidth: nil,
                    pixelScale: s,
                    emitGlyphs: true
                )
                let cw = max(keyLook.height, ceil(shapedKey.size.x) + 2.0 * keyLook.padX)
                caps.append((shapedKey, cw))
            }
        }
        let keysW: Float
        if caps.isEmpty {
            keysW = 0.0
        } else {
            let capSum = caps.reduce(Float(0)) { $0 + $1.1 }
            let capGaps = keyLook.gap * Float(caps.count - 1)
            let lead = words.isEmpty ? 0.0 : keyLook.lead
            keysW = capSum + capGaps + lead
        }

        let hasWords = !words.isEmpty
        var shapedWords: ShapedText? = nil
        var tw: Float = 0.0
        var th: Float = 0.0
        if hasWords {
            let maxTextW = max(1.0, wrap - keysW)
            let shaped = textSystem.shape(
                text: words,
                spans: nil,
                style: look.font,
                maxWidth: maxTextW,
                pixelScale: s,
                emitGlyphs: true
            )
            shapedWords = shaped
            tw = ceil(shaped.size.x)
            th = ceil(shaped.size.y)
        }
        let ch = caps.isEmpty ? th : max(th, keyLook.height)
        rows.append(HelpTipRow(
            hasWords: hasWords,
            shaped: shapedWords,
            tw: tw,
            th: th,
            ch: ch,
            caps: caps,
            keysW: keysW
        ))
    }

    let rowGaps = look.rowGap * Float(max(0, rows.count - 1))
    let w = (rows.map { $0.tw + $0.keysW }.max() ?? 0.0) + 2.0 * padX
    let h = rows.reduce(Float(0)) { $0 + $1.ch } + rowGaps + 2.0 * padY
    let below = look.gapBelow
    let over = look.gapOver

    var x: Float
    var y: Float
    switch tip.side {
    case .left, .right:
        let left = e.x - over - w
        let right = e.z + over
        let fitsLeft = left >= margin
        let fitsRight = right + w <= vw - margin
        let onLeft = (tip.side == .left) ? (fitsLeft || !fitsRight) : (fitsLeft && !fitsRight)
        x = onLeft ? left : right
        y = (e.y + e.w - h) * 0.5
    case .top, .bottom, nil:
        y = e.w + below
        if tip.side == .top && e.y - over - h >= margin {
            y = e.y - over - h
        } else if y + h > vh - margin && e.y - below - h >= margin {
            y = e.y - below - h
        }
        x = (e.x + e.z - w) * 0.5
    }

    x = min(max(vw - w - margin, margin), max(margin, x))
    y = min(max(vh - h - margin, margin), max(margin, y))

    let full = SIMD4<Float>((x * s).rounded(), (y * s).rounded(), (w * s).rounded(), (h * s).rounded())
    let k = tip.scale
    let alpha = tip.alpha
    let pivot: SIMD2<Float>
    if x >= e.z {
        let py = min(full.y + full.w, max(full.y, ((e.y + e.w) * 0.5 * s)))
        pivot = SIMD2<Float>(full.x, py)
    } else if x + w <= e.x {
        let py = min(full.y + full.w, max(full.y, ((e.y + e.w) * 0.5 * s)))
        pivot = SIMD2<Float>(full.x + full.z, py)
    } else {
        let px = min(full.x + full.z, max(full.x, ((e.x + e.z) * 0.5 * s)))
        let py = y >= e.w ? full.y : (full.y + full.w)
        pivot = SIMD2<Float>(px, py)
    }

    @inline(__always)
    func scalePoint(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(pivot.x + (p.x - pivot.x) * k, pivot.y + (p.y - pivot.y) * k)
    }

    @inline(__always)
    func scaleRect(_ r: SIMD4<Float>) -> SIMD4<Float> {
        let o = scalePoint(SIMD2<Float>(r.x, r.y))
        return SIMD4<Float>(o.x, o.y, r.z * k, r.w * k)
    }

    let fullClip = SIMD4<Float>(0, 0, vw * s, vh * s)
    let cardRectPx = scaleRect(full)
    let cardRadiiPx = SIMD4<Float>(repeating: look.radius * s * k)

    for sh in look.shadowLayers where !sh.inset && sh.color.a > 0.001 {
        let sc = sh.color.scaleAlpha(alpha).simd4(srgb: srgbBlend)
        primitives.append(.dropShadow(
            rect: cardRectPx,
            radii: cardRadiiPx,
            color: sc,
            blur: sh.blur * s,
            spread: sh.spread * s,
            offset: SIMD2<Float>(sh.x * s, sh.y * s),
            cutoutInner: look.fill.a < 0.999 && sh.blur == 0 && sh.spread > 0,
            clip: fullClip
        ))
    }

    let ringW = look.ringSpec.map { max(1.0, $0.width * s) } ?? 0.0
    let ringCol = (look.ringSpec?.color ?? .transparent).scaleAlpha(alpha).simd4(srgb: srgbBlend)
    let fillCol = look.fill.scaleAlpha(alpha).simd4(srgb: srgbBlend)
    primitives.append(.roundedRect(
        rect: cardRectPx,
        radii: cardRadiiPx,
        fill: fillCol,
        borderColor: ringCol,
        borderWidth: ringW,
        clip: fullClip
    ))

    func emitShapedGlyphs(_ shaped: ShapedText, originPx: SIMD2<Float>, inkColor: Color) {
        let scaledOrigin = scalePoint(originPx)
        for g in shaped.glyphs {
            let gc = (g.color ?? inkColor).scaleAlpha(alpha).simd4(srgb: srgbBlend)
            let rect = SIMD4<Float>(scaledOrigin.x + g.rect.x * s * k, scaledOrigin.y + g.rect.y * s * k,
                                    g.rect.z * s * k, g.rect.w * s * k)
            let primitive = runtime.referenceTextPrimitive(g, rect: rect, ink: gc, clip: fullClip)
            if primitive.kind == .glyph { recordGlyphPage(primitives.count, g.atlasPage) }
            primitives.append(primitive)
        }
    }

    var topPx = full.y + padY * s
    for row in rows {
        var atPx = full.x + padX * s
        if row.hasWords, let shaped = row.shaped {
            let wordOrigin = SIMD2<Float>(atPx, topPx + ((row.ch - row.th) * 0.5 * s).rounded())
            emitShapedGlyphs(shaped, originPx: wordOrigin, inkColor: look.ink)
            atPx += (row.tw + keyLook.lead) * s
        }
        let capFill = keyLook.fill.scaleAlpha(alpha).simd4(srgb: srgbBlend)
        let capRadii = SIMD4<Float>(repeating: keyLook.radius * s * k)
        for (shapedCap, cw) in row.caps {
            let capPx = SIMD4<Float>(
                atPx.rounded(),
                (topPx + ((row.ch - keyLook.height) * 0.5 * s).rounded()).rounded(),
                (cw * s).rounded(),
                (keyLook.height * s).rounded()
            )
            primitives.append(.roundedRect(
                rect: scaleRect(capPx),
                radii: capRadii,
                fill: capFill,
                clip: fullClip
            ))
            let lw = shapedCap.size.x * s
            let lh = shapedCap.size.y * s
            let keyOrigin = SIMD2<Float>(
                capPx.x + ((capPx.z - lw) * 0.5).rounded(),
                capPx.y + ((capPx.w - lh) * 0.5).rounded()
            )
            emitShapedGlyphs(shapedCap, originPx: keyOrigin, inkColor: keyLook.ink)
            atPx += (cw + keyLook.gap) * s
        }
        topPx += (row.ch + look.rowGap) * s
    }

    return SIMD4<Float>(x, y, w, h)
}
