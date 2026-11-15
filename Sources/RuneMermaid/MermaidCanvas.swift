import Foundation
import Rune

enum CanvasConstants {
    static let cardPad: Float = 16.0
    static let titleGap: Float = 12.0
    static let wrapWidth: Float = 200.0
}

enum MermaidTextMeasurer {
    private static let textSystem = TextSystem()

    static func measure(_ s: String, font: TextStyle, maxWidth: Float? = nil) -> Vec2 {
        textSystem.measure(s, style: font, maxWidth: maxWidth, pixelScale: 1.0)
    }
}

struct Measured: Equatable {
    var text: String = ""
    var size: Vec2 = .zero
    var wrap: Bool = false

    static let empty = Measured()
}

func measureText(_ s: String, font: TextStyle) -> Measured {
    measureWrap(s, font: font, maxWidth: CanvasConstants.wrapWidth)
}

func measureWrap(_ s: String, font: TextStyle, maxWidth: Float) -> Measured {
    guard !s.isEmpty else { return .empty }
    let full = MermaidTextMeasurer.measure(s, font: font, maxWidth: nil)
    if full.x <= maxWidth {
        return Measured(text: s, size: full, wrap: false)
    }
    let wrapped = MermaidTextMeasurer.measure(s, font: font, maxWidth: maxWidth)
    return Measured(text: s, size: wrapped, wrap: true)
}

func measureBalanced(_ s: String, font: TextStyle) -> Measured {
    var m = measureText(s, font: font)
    if !m.wrap { return m }
    var lo: Float = 0.0
    var hi: Float = m.size.x
    while hi - lo > 1.0 {
        let mid = (lo + hi) * 0.5
        let sz = MermaidTextMeasurer.measure(s, font: font, maxWidth: mid)
        if sz.y > m.size.y + 0.5 {
            lo = mid
        } else {
            hi = mid
            m.size.x = sz.x
        }
    }
    return m
}

func overColor(_ top: Color, _ bottom: Color) -> Color {
    let a = top.a + bottom.a * (1.0 - top.a)
    if a <= 1e-6 { return .transparent }
    func mix(_ t: Float, _ b: Float) -> Float {
        (t * top.a + b * bottom.a * (1.0 - top.a)) / a
    }
    return Color(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a: a)
}

func groupBorder(_ paint: MermaidTheme) -> Color {
    paint.nodeBorder.alpha(paint.nodeBorder.a * 0.7)
}

enum CanvasOp: Equatable {
    case fill(points: [Vec2], color: Color)
    case stroke(points: [Vec2], closed: Bool, width: Float, roundCap: Bool, color: Color)

    func mapped(by map: (Vec2) -> Vec2) -> CanvasOp {
        switch self {
        case let .fill(points, color):
            return .fill(points: points.map(map), color: color)
        case let .stroke(points, closed, width, roundCap, color):
            return .stroke(points: points.map(map), closed: closed, width: width, roundCap: roundCap, color: color)
        }
    }

    func toShape(points override: [Vec2]? = nil) -> Shape {
        switch self {
        case let .fill(points, color):
            let pts = override ?? points
            var path = VectorPath()
            if let first = pts.first {
                path.moveTo(first.x, first.y)
                for p in pts.dropFirst() { path.lineTo(p.x, p.y) }
                path.close()
            }
            return .fill(path, color: color)
        case let .stroke(points, closed, width, roundCap, color):
            let pts = override ?? points
            var path = VectorPath()
            if let first = pts.first {
                path.moveTo(first.x, first.y)
                for p in pts.dropFirst() { path.lineTo(p.x, p.y) }
                if closed { path.close() }
            }
            return .stroke(path, color: color, width: width, roundCap: roundCap)
        }
    }
}

struct CanvasLabel {
    let text: String
    let at: Vec2
    let size: Vec2
    let font: TextStyle
    let color: Color
    let wrap: Bool
    let align: TextAlign
}

struct Canvas {
    var ops: [CanvasOp] = []
    var labels: [CanvasLabel] = []
    var regions: [[Vec2]] = []
    var traces: [HoverTrace] = []
    var hover: (MermaidHover, Color)? = nil
    var marks: [PartMark] = []
    var names: PartNames = PartNames()
    var turned: Bool = false

    static func room(for paint: MermaidTheme) -> Float {
        paint.maxWidth - 2.0 * CanvasConstants.cardPad - 2.0
    }

    static func fitScale(width: Float, paint: MermaidTheme) -> Float {
        let r = room(for: paint)
        if width <= r { return 1.0 }
        return max(r / width, min(max(paint.minScale, 0.0), 1.0))
    }

    mutating func fill(_ points: [Vec2], color: Color) {
        guard points.count >= 3 else { return }
        ops.append(.fill(points: points, color: color))
    }

    mutating func stroke(_ points: [Vec2], closed: Bool, width: Float, color: Color, roundCap: Bool = true) {
        guard points.count >= 2 else { return }
        ops.append(.stroke(points: points, closed: closed, width: width, roundCap: roundCap, color: color))
    }

    mutating func shape(_ points: [Vec2], fill fillColor: Color, border: Color, width: Float) {
        fill(points, color: fillColor)
        stroke(points, closed: true, width: width, color: border)
    }

    mutating func dashed(_ points: [Vec2], width: Float, color: Color, on: Float, off: Float) {
        guard points.count >= 2 else { return }
        var dash: [Vec2] = []
        var drawing = true
        var left = on
        var budget = 20_000

        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let len = CanvasMath.dist(a, b)
            guard len.isFinite, len > 0 else { continue }
            var t: Float = 0.0
            while t < len {
                guard budget > 0 else { return }
                budget -= 1
                let step = min(left, len - t)
                let p0 = CanvasMath.lerp(a, b, t / len)
                let p1 = CanvasMath.lerp(a, b, (t + step) / len)
                if drawing {
                    if dash.isEmpty { dash.append(p0) }
                    dash.append(p1)
                }
                t += step
                left -= step
                if left <= 1e-3 {
                    if drawing && dash.count >= 2 {
                        ops.append(.stroke(points: dash, closed: false, width: width, roundCap: false, color: color))
                    }
                    dash.removeAll(keepingCapacity: true)
                    drawing.toggle()
                    left = drawing ? on : off
                }
            }
        }
        if dash.count >= 2 {
            ops.append(.stroke(points: dash, closed: false, width: width, roundCap: false, color: color))
        }
    }

    mutating func label(_ m: Measured, center: Vec2, font: TextStyle, color: Color, align: TextAlign) {
        guard !m.text.isEmpty else { return }
        let at = Vec2(center.x - m.size.x * 0.5, center.y - m.size.y * 0.5)
        labelAt(m, at: at, font: font, color: color, align: align)
    }

    mutating func labelAt(_ m: Measured, at: Vec2, font: TextStyle, color: Color, align: TextAlign) {
        guard !m.text.isEmpty else { return }
        labels.append(CanvasLabel(text: m.text, at: at, size: m.size, font: font, color: color, wrap: m.wrap, align: align))
    }

    mutating func append(_ other: Canvas) {
        let base = ops.count
        let shift = labels.count
        marks.append(PartMark(opIndex: base, labelIndex: shift, part: nil))
        for m in other.marks {
            marks.append(PartMark(opIndex: m.opIndex + base, labelIndex: m.labelIndex + shift, part: m.part))
        }
        ops.append(contentsOf: other.ops)
        labels.append(contentsOf: other.labels)
        for t in other.traces {
            traces.append(HoverTrace(
                ends: t.ends,
                part: t.part,
                ops: t.ops,
                line: t.line,
                label: t.label.map { ($0.index + shift, $0.rect) }
            ))
        }
    }

    mutating func part(_ p: Part?) {
        marks.append(PartMark(opIndex: ops.count, labelIndex: labels.count, part: p))
    }

    func partKey(_ p: Part) -> (String, PartKind) {
        let (k, kind) = names.key(for: p)
        if turned && kind == .edge {
            return ("\(k)|v", kind)
        }
        return (k, kind)
    }

    func currentPart() -> Part? {
        marks.last?.part
    }

    func runs() -> [(Part?, Range<Int>, Range<Int>)] {
        var out: [(Part?, Range<Int>, Range<Int>)] = []
        var atOp = 0
        var atLabel = 0
        var atPart: Part? = nil
        let allMarks = marks + [PartMark(opIndex: ops.count, labelIndex: labels.count, part: nil)]
        for m in allMarks {
            if m.opIndex > atOp || m.labelIndex > atLabel {
                out.append((atPart, atOp..<m.opIndex, atLabel..<m.labelIndex))
            }
            atOp = m.opIndex
            atLabel = m.labelIndex
            atPart = m.part
        }
        return out
    }

    func bounds() -> (Float, Float, Float, Float) {
        var x0 = Float.greatestFiniteMagnitude
        var y0 = Float.greatestFiniteMagnitude
        var x1 = -Float.greatestFiniteMagnitude
        var y1 = -Float.greatestFiniteMagnitude

        func add(_ p: Vec2, _ r: Float) {
            x0 = min(x0, p.x - r)
            y0 = min(y0, p.y - r)
            x1 = max(x1, p.x + r)
            y1 = max(y1, p.y + r)
        }

        for op in ops {
            switch op {
            case let .fill(points, _):
                for p in points { add(p, 0) }
            case let .stroke(points, _, width, _, _):
                for p in points { add(p, width * 0.5) }
            }
        }
        for l in labels {
            add(l.at, 0)
            add(Vec2(l.at.x + l.size.x, l.at.y + l.size.y), 0)
        }
        return x0 > x1 ? (0, 0, 0, 0) : (x0, y0, x1, y1)
    }

    var width: Float {
        let b = bounds()
        return b.2 - b.0
    }

    func drawn() -> (Float, Float, Float, Float) {
        let b = bounds()
        let origin = SteadyLayout.origin(bounds: b, turned: turned)
        return (origin.x, origin.y, b.2, b.3)
    }

    func finishFit(paint: MermaidTheme) -> MermaidScene? {
        let b = drawn()
        let scale = Canvas.fitScale(width: b.2 - b.0, paint: paint)
        return finish(scale: scale, paint: paint)
    }

    mutating func finishFitMutating(paint: MermaidTheme) -> MermaidScene? {
        let b = drawn()
        let scale = Canvas.fitScale(width: b.2 - b.0, paint: paint)
        return finish(scale: scale, paint: paint)
    }

    func finish(scale: Float, paint: MermaidTheme) -> MermaidScene? {
        if ops.isEmpty && labels.isEmpty { return nil }
        var copy = self
        InkFlattener.flatten(ops: &copy.ops, traces: &copy.traces, surface: paint.surface)
        let b = copy.drawn()
        let pad = 1.0 / scale
        let map: (Vec2) -> Vec2 = { p in
            Vec2(p.x - b.0 + pad, p.y - b.1 + pad)
        }
        let (pieces, labelKeys) = PartSplitter.split(canvas: copy, map: map)
        let hovers = copy.hovers(map: map)
        let mappedLabels = copy.labels.map {
            CanvasLabel(text: $0.text, at: map($0.at), size: $0.size, font: $0.font, color: $0.color, wrap: $0.wrap, align: $0.align)
        }
        let full = Vec2(b.2 - b.0 + 2.0 * pad, b.3 - b.1 + 2.0 * pad)
        let size = Vec2(full.x * scale, full.y * scale)
        let lit = copy.hover?.1 ?? .transparent
        return MermaidScene(
            title: nil,
            size: size,
            full: full,
            scale: scale,
            pieces: pieces,
            labels: mappedLabels,
            labelKeys: labelKeys,
            hovers: hovers,
            lit: lit,
            ops: copy.ops
        )
    }
}

/// Text highlights for a drawn label, by its element key (upstream `canvas::Marks`).
typealias MermaidMarks = (String) -> [TextHighlight]

/// `el` with `marks(key)` applied as text highlights, or untouched without marks (`canvas::marked`).
func mermaidMarked<State>(_ el: El<State>, _ key: String, _ marks: MermaidMarks?) -> El<State> {
    if let paint = marks { return el.textHighlights(paint(key)) }
    return el
}

struct MermaidScene: @unchecked Sendable {
    var title: String?
    var size: Vec2
    let full: Vec2
    let scale: Float
    let pieces: [ScenePiece]
    let labels: [CanvasLabel]
    let labelKeys: [LabelKey]
    let hovers: [HoverSpot]
    let lit: Color
    let ops: [CanvasOp]

    func withTitle(_ title: String?) -> MermaidScene {
        var copy = self
        if let t = title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.title = t
        }
        return copy
    }

    func el<State>(paint: MermaidTheme, streaming: Bool = false) -> El<State> {
        let still: (Transition) -> Transition = { streaming ? $0 : .none }
        var card = col() as El<State>
        card = card
            .wFull()
            .itemsCenter()
            .p(CanvasConstants.cardPad)
            .rounded(6.0)
            .bg(paint.surface)
            .border(0.5, paint.surfaceBorder)
            .clipRounded(6.0)
            .animateLayout()
            .transition(still(.opacity))
        if size.x > Canvas.room(for: paint) + 0.5 {
            card = card.clipFade(left: CanvasConstants.cardPad, top: 0, right: CanvasConstants.cardPad, bottom: 0)
        }
        if let titleEl: El<State> = makeTitleEl(paint: paint, streaming: streaming, marks: nil) {
            card = card.gap(CanvasConstants.titleGap).child(titleEl)
        }
        return card.child(diagramEl(streaming: streaming, marks: nil))
    }

    func drawing<State>(paint: MermaidTheme, marks: MermaidMarks? = nil) -> (El<State>, Vec2) {
        var sz = size
        var out = col() as El<State>
        out = out.itemsCenter()
        if let titleEl: El<State> = makeTitleEl(paint: paint, streaming: false, marks: marks), let t = title {
            let m = measureText(t, font: titleFont(paint)).size
            sz = Vec2(max(sz.x, m.x + 2.0), sz.y + m.y + CanvasConstants.titleGap)
            out = out.gap(CanvasConstants.titleGap).child(titleEl)
        }
        return (out.child(diagramEl(streaming: false, marks: marks)), sz)
    }

    private func makeTitleEl<State>(paint: MermaidTheme, streaming: Bool, marks: MermaidMarks?) -> El<State>? {
        guard let title else { return nil }
        let still: Transition = streaming ? .opacity : .none
        let t: El<State> = text(title)
            .key("title")
            .font(titleFont(paint))
            .color(paint.text)
            .transition(still)
        return mermaidMarked(t, "title", marks)
    }

    private func diagramEl<State>(streaming: Bool, marks: MermaidMarks?) -> El<State> {
        let still: (Transition) -> Transition = { streaming ? $0 : .none }
        var body = Rune.el() as El<State>
        body = body.key("fit").absolute(x: 0, y: 0).size(size.x, size.y).transition(.none)
        for p in pieces {
            body = body.child(p.el(streaming: streaming, scale: scale).a11yHidden())
        }
        func makeLabel(_ l: CanvasLabel, color: Color) -> El<State> {
            var t = text(l.text) as El<State>
            t = t.font(l.font).color(color).textAlign(l.align).w(l.size.x + 2.0)
            if !l.wrap { t = t.noWrap() }
            return t
        }
        for (l, lk) in zip(labels, labelKeys) {
            let (enter, delay) = lk.kind?.labelEnter ?? (.opacity, 0.0)
            var t = mermaidMarked(makeLabel(l, color: l.color), lk.key, marks)
                .absolute(x: 0, y: 0)
                .offset((l.at.x - 1.0) * scale, l.at.y * scale)
                .origin(0.0, 0.0)
                .scale(scale)
                .key(lk.key)
                .transition(still(enter))
            if streaming {
                t = t.animate(MotionTokens.SETTLE).animateLayout()
                if delay > 0.0 {
                    t = t.enterDelay(delay)
                }
            }
            body = body.child(t)
        }
        let exit = still(Transition(insertion: .identity, removal: TransitionEffect(zeroOpacity: 0)))
        for s in hovers {
            let r = s.rect
            var glow = (Rune.el() as El<State>)
                .absolute(x: 0, y: 0)
                .offset(-r.0 * scale, -r.1 * scale)
                .size(full.x, full.y)
                .origin(0.0, 0.0)
                .scale(scale)
                .groupOpacity(0.0, 1.0)
                .instantChanges()
                .transition(.none)
            glow.shapes = s.shapes
            var glowChildren: [El<State>] = []
            for i in s.labels where i >= 0 && i < labels.count {
                let l = labels[i]
                // A hover copy carries the same marks as the label underneath it.
                glowChildren.append(
                    mermaidMarked(makeLabel(l, color: lit), labelKeys[i].key, marks)
                        .absolute(x: 0, y: 0)
                        .offset(l.at.x - 1.0, l.at.y)
                        .key("t\(i)")
                        .transition(.none)
                )
            }
            if !glowChildren.isEmpty {
                glow = glow.children(glowChildren)
            }
            var spot = (Rune.el() as El<State>)
                .key(s.key)
                .absolute(x: 0, y: 0)
                .offset(r.0 * scale, r.1 * scale)
                .size(r.2 * scale, r.3 * scale)
                .hoverGroup()
                .transition(exit)
                .child(glow)
                .a11yHidden()
            if streaming {
                spot = spot.animate(MotionTokens.SETTLE).animateLayout()
            }
            body = body.child(spot)
        }
        return (Rune.el() as El<State>)
            .key("diagram")
            .size(size.x, size.y)
            .transition(still(.opacity))
            .child(body)
    }

    private func titleFont(_ paint: MermaidTheme) -> TextStyle {
        var f = paint.font
        f.size = paint.font.size + 1.0
        f.lineHeight = paint.font.resolvedLineHeight + 2.0
        f.weight = 600.0
        return f
    }
}

// MARK: - Geometry Helpers

extension Vec2 {
    static func + (lhs: Vec2, rhs: Vec2) -> Vec2 { Vec2(lhs.x + rhs.x, lhs.y + rhs.y) }
    static func - (lhs: Vec2, rhs: Vec2) -> Vec2 { Vec2(lhs.x - rhs.x, lhs.y - rhs.y) }
    static func * (lhs: Vec2, rhs: Float) -> Vec2 { Vec2(lhs.x * rhs, lhs.y * rhs) }
    static func * (lhs: Float, rhs: Vec2) -> Vec2 { Vec2(lhs * rhs.x, lhs * rhs.y) }
}

enum CanvasMath {
    static func dist(_ a: Vec2, _ b: Vec2) -> Float {
        hypotf(b.x - a.x, b.y - a.y)
    }

    static func lerp(_ a: Vec2, _ b: Vec2, _ t: Float) -> Vec2 {
        Vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }

    static func unit(_ a: Vec2, _ b: Vec2) -> Vec2 {
        let d = max(dist(a, b), 1e-6)
        return Vec2((b.x - a.x) / d, (b.y - a.y) / d)
    }

    static func roundedRect(x0: Float, y0: Float, x1: Float, y1: Float, r: Float) -> [Vec2] {
        let radius = max(0.0, min(r, min((x1 - x0) * 0.5, (y1 - y0) * 0.5)))
        if radius < 0.5 {
            return [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
        }
        let steps = 6
        var pts: [Vec2] = []
        pts.reserveCapacity(4 * (steps + 1))
        let corners: [(Vec2, Float)] = [
            (Vec2(x1 - radius, y0 + radius), -90.0),
            (Vec2(x1 - radius, y1 - radius), 0.0),
            (Vec2(x0 + radius, y1 - radius), 90.0),
            (Vec2(x0 + radius, y0 + radius), 180.0),
        ]
        for (c, start) in corners {
            for i in 0...steps {
                let rad = (start + 90.0 * Float(i) / Float(steps)) * (.pi / 180.0)
                pts.append(Vec2(c.x + radius * cosf(rad), c.y + radius * sinf(rad)))
            }
        }
        return pts
    }

    static func arc(center: Vec2, rx: Float, ry: Float, a0: Float, a1: Float, steps: Int) -> [Vec2] {
        (0...steps).map { i in
            let a = (a0 + (a1 - a0) * Float(i) / Float(steps)) * (.pi / 180.0)
            return Vec2(center.x + rx * cosf(a), center.y + ry * sinf(a))
        }
    }

    static func ellipse(center: Vec2, rx: Float, ry: Float) -> [Vec2] {
        var pts = arc(center: center, rx: rx, ry: ry, a0: 0.0, a1: 360.0, steps: 48)
        if !pts.isEmpty { pts.removeLast() }
        return pts
    }

    static func arrowhead(tip: Vec2, dir: Vec2, len: Float, width: Float) -> [Vec2] {
        let base = Vec2(tip.x - dir.x * len, tip.y - dir.y * len)
        let n = Vec2(-dir.y * width * 0.5, dir.x * width * 0.5)
        return [tip, Vec2(base.x + n.x, base.y + n.y), Vec2(base.x - n.x, base.y - n.y)]
    }

    static func diamondHead(tip: Vec2, dir: Vec2, len: Float, width: Float) -> [Vec2] {
        let mid = Vec2(tip.x - dir.x * len * 0.5, tip.y - dir.y * len * 0.5)
        let tail = Vec2(tip.x - dir.x * len, tip.y - dir.y * len)
        let n = Vec2(-dir.y * width * 0.5, dir.x * width * 0.5)
        return [tip, Vec2(mid.x + n.x, mid.y + n.y), tail, Vec2(mid.x - n.x, mid.y - n.y)]
    }

    static func smooth(_ pts: [Vec2]) -> [Vec2] {
        guard pts.count >= 3 else { return pts }
        let n = pts.count
        func tangent(_ i: Int) -> Vec2 {
            let (a, b): (Vec2, Vec2) = if i == 0 {
                (pts[0], pts[1])
            } else if i == n - 1 {
                (pts[n - 2], pts[n - 1])
            } else {
                (pts[i - 1], pts[i + 1])
            }
            let k: Float = (i == 0 || i == n - 1) ? 1.0 : 0.5
            return Vec2((b.x - a.x) * k, (b.y - a.y) * k)
        }
        var out = [pts[0]]
        for i in 0..<(n - 1) {
            let a = pts[i]
            let b = pts[i + 1]
            let ta = tangent(i)
            let tb = tangent(i + 1)
            let c1 = Vec2(a.x + ta.x / 3.0, a.y + ta.y / 3.0)
            let c2 = Vec2(b.x - tb.x / 3.0, b.y - tb.y / 3.0)
            let steps = Int(min(max(ceilf((dist(a, c1) + dist(c1, c2) + dist(c2, b)) / 4.0), 2.0), 48.0))
            for s in 1...steps {
                let t = Float(s) / Float(steps)
                let u = 1.0 - t
                let b0 = u * u * u
                let b1 = 3.0 * u * u * t
                let b2 = 3.0 * u * t * t
                let b3 = t * t * t
                out.append(Vec2(
                    b0 * a.x + b1 * c1.x + b2 * c2.x + b3 * b.x,
                    b0 * a.y + b1 * c1.y + b2 * c2.y + b3 * b.y
                ))
            }
        }
        return out
    }
}
