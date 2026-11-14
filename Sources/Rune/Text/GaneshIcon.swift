// Port of upstream `crates/rune/src/text/{area.rs, icon.rs}`:
// Skia Ganesh icon element dispatch (rects, round rects, ovals, quads, hairlines, convex strokes,
// convex quad-edge fills, analytic anti-aliased paths) and SVG body / group inheritance rasterizer.

import Foundation

internal enum GaneshArea {
    enum Shape {
        case path([GEl])
        case oval(center: GPoint, radii: GPoint)
        case rounded(lo: GPoint, hi: GPoint, r: Float)
    }

    struct Pen {
        var width: Float
        var cap: GLineCap
        var join: GLineJoin
        var miterLimit: Float
    }

    struct Round {
        var lo: GPoint
        var hi: GPoint
        var r: Float

        func inside(_ q: GPoint) -> Float {
            let cx = (lo.x + hi.x) * 0.5, cy = (lo.y + hi.y) * 0.5
            let rad = min(r, min((hi.x - lo.x) * 0.5, (hi.y - lo.y) * 0.5))
            let dx = abs(q.x - cx) - ((hi.x - lo.x) * 0.5 - rad)
            let dy = abs(q.y - cy) - ((hi.y - lo.y) * 0.5 - rad)
            return rad - (hypot(max(Float(0), dx), max(Float(0), dy)) + min(max(dx, dy), Float(0)))
        }
    }

    enum Op {
        case hairline(Float)
        case rect(outer: (GPoint, GPoint), inner: (GPoint, GPoint)?)
        case strokeRect(outside: (GPoint, GPoint), inside: (GPoint, GPoint)?, hw: Float)
        case quad(GPoint, GPoint, GPoint, GPoint)
        case round(outer: Round, inner: Round?)
        case convexStroke
        case path

        func render(px: Int, out: inout [UInt8]) {
            for y in 0..<px {
                for x in 0..<px {
                    let q = GPoint(x: Float(x) + 0.5, y: Float(y) + 0.5)
                    let c: Float
                    switch self {
                    case .rect(let outer, let inner):
                        c = ramp(insideRect(outer, q)) - (inner.map { ramp(insideRect($0, q)) } ?? 0)
                    case .strokeRect(let outside, let inside, let hw):
                        let inset = min(hw, Float(0.5))
                        let full: Float = inset < 0.5 ? (2.0 * inset / (inset + 0.5)) : 1.0
                        let outset = 1.0 - inset
                        let a = gBound(insideRect(outside, q) + outset, 0, 1)
                        let b: Float
                        if let r = inside {
                            let hx = (r.1.x - r.0.x) * 0.5, hy = (r.1.y - r.0.y) * 0.5
                            let backset = max(Float(0), 1.0 - min(hx, hy) / outset)
                            if backset == 0 {
                                b = gBound(outset - insideRect(r, q), 0, 1)
                            } else {
                                let xv = (min(q.x - r.0.x, r.1.x - q.x) + inset) / (inset + min(hx, outset))
                                let yv = (min(q.y - r.0.y, r.1.y - q.y) + inset) / (inset + min(hy, outset))
                                b = 1.0 - (1.0 - backset) * gBound(min(xv, yv), 0, 1)
                            }
                        } else {
                            b = 1.0
                        }
                        c = full * min(a, b)
                    case .quad(let p0, let p1, let p2, let p3):
                        c = ramp(insideQuad(p0, p1, p2, p3, q))
                    case .round(let outer, let inner):
                        c = ramp(outer.inside(q)) * (inner.map { ramp(-$0.inside(q)) } ?? 1.0)
                    case .hairline, .path, .convexStroke:
                        c = 0
                    }
                    out[y * px + x] = UInt8((gBound(c, 0, 1) * 255.0).rounded())
                }
            }
        }
    }

    @inline(__always) private static func ramp(_ inside: Float) -> Float { gBound(0.5 + inside, 0, 1) }
    @inline(__always) private static func grow(_ r: (GPoint, GPoint), by: Float) -> (GPoint, GPoint) {
        (GPoint(x: r.0.x - by, y: r.0.y - by), GPoint(x: r.1.x + by, y: r.1.y + by))
    }
    @inline(__always) private static func insideRect(_ r: (GPoint, GPoint), _ q: GPoint) -> Float {
        min(min(q.x - r.0.x, r.1.x - q.x), min(q.y - r.0.y, r.1.y - q.y))
    }
    private static func insideQuad(_ q0: GPoint, _ q1: GPoint, _ q2: GPoint, _ q3: GPoint, _ q: GPoint) -> Float {
        let cr = (q1.x - q0.x) * (q2.y - q0.y) - (q1.y - q0.y) * (q2.x - q0.x)
        let wind: Float = cr > 0 ? 1 : (cr < 0 ? -1 : 0)
        let pts = [q0, q1, q2, q3]
        var best = Float.greatestFiniteMagnitude
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            let len = max(hypot(b.x - a.x, b.y - a.y), Float(1e-6))
            let d = wind * ((b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)) / len
            if d < best { best = d }
        }
        return best
    }

    static func elements(of shape: Shape) -> [GEl] {
        switch shape {
        case .path(let els): return els
        case .oval(let center, let radii): return GaneshConvex.oval(center: center, radii: radii)
        case .rounded: return []
        }
    }

    private static func isSimilarity(_ ctm: GTransform) -> Bool {
        let a = ctm.xx, b = ctm.xy, c = ctm.yx, d = ctm.yy
        return abs(a * a + b * b - (c * c + d * d)) <= 1.0 / 4096.0 && abs(a * c + b * d) <= 1.0 / 4096.0
    }

    private static func linearizes(_ pen: Pen, scale: Float, ctm: GTransform) -> Bool {
        pen.join != .round && pen.width * scale > 1.0 + 1.0 / 256.0 && pen.width * scale <= 20.0 && isSimilarity(ctm)
    }

    private static func rectOp(_ r: (GPoint, GPoint), pen: Pen?, hw: Float, scale: Float) -> Op {
        guard let pen else { return .rect(outer: r, inner: nil) }
        if pen.join == .miter {
            let hollow = (r.1.x - r.0.x) > 2.0 * hw && (r.1.y - r.0.y) > 2.0 * hw
            return .strokeRect(outside: grow(r, by: hw), inside: hollow ? grow(r, by: -hw) : nil, hw: hw)
        }
        return thin(pen, scale: scale)
    }

    private static func thin(_ pen: Pen?, scale: Float) -> Op {
        if let p = pen, p.width * scale <= 1.0 + 1.0 / 256.0 {
            return .hairline(p.width * scale)
        }
        return .path
    }

    private static func ringOp(_ shape: Round, hw: Float?) -> Op {
        guard let hw else { return .round(outer: shape, inner: nil) }
        let outer = Round(lo: GPoint(x: shape.lo.x - hw, y: shape.lo.y - hw), hi: GPoint(x: shape.hi.x + hw, y: shape.hi.y + hw), r: shape.r + hw)
        let inner = Round(lo: GPoint(x: shape.lo.x + hw, y: shape.lo.y + hw), hi: GPoint(x: shape.hi.x - hw, y: shape.hi.y - hw), r: max(Float(0), shape.r - hw))
        let hollow = inner.hi.x > inner.lo.x && inner.hi.y > inner.lo.y
        return .round(outer: outer, inner: hollow ? inner : nil)
    }

    private static func lineOp(_ a: GPoint, _ b: GPoint, cap: GLineCap, hw: Float, upright: Bool) -> Op? {
        let ext = cap == .butt ? Float(0) : hw
        let isThin = hw * 2.0 < 1.0 - 1.0 / 256.0
        let lo = GPoint(x: min(a.x, b.x), y: min(a.y, b.y))
        let hi = GPoint(x: max(a.x, b.x), y: max(a.y, b.y))
        if upright && (a.x == b.x || a.y == b.y) {
            let (ox, oy): (Float, Float)
            if a.y == b.y && a.x != b.x { (ox, oy) = (ext, hw) }
            else if a.x == b.x && a.y != b.y { (ox, oy) = (hw, ext) }
            else { (ox, oy) = (ext, ext) }
            let l2 = GPoint(x: lo.x - ox, y: lo.y - oy), h2 = GPoint(x: hi.x + ox, y: hi.y + oy)
            if h2.x <= l2.x || h2.y <= l2.y { return nil }
            if cap == .round { return .round(outer: Round(lo: l2, hi: h2, r: hw), inner: nil) }
            if isThin { return nil }
            return .rect(outer: (l2, h2), inner: nil)
        }
        let len = hypot(b.x - a.x, b.y - a.y)
        if cap == .round || isThin || len < 1e-6 { return nil }
        let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
        let a2 = GPoint(x: a.x - ux * ext, y: a.y - uy * ext)
        let b2 = GPoint(x: b.x + ux * ext, y: b.y + uy * ext)
        let nx = -uy * hw, ny = ux * hw
        return .quad(
            GPoint(x: a2.x + nx, y: a2.y + ny),
            GPoint(x: b2.x + nx, y: b2.y + ny),
            GPoint(x: b2.x - nx, y: b2.y - ny),
            GPoint(x: a2.x - nx, y: a2.y - ny)
        )
    }

    private static func rectCorners(_ path: [GEl], ctm: GTransform) -> (GPoint, GPoint)? {
        guard ctm.xy == 0 && ctm.yx == 0 else { return nil }
        guard path.count >= 2, case .move(let start) = path.first!, case .close = path.last! else { return nil }
        var pts: [GPoint] = [start]
        for cmd in path.dropFirst().dropLast() {
            guard case .line(let p) = cmd else { return nil }
            pts.append(p)
        }
        if pts.count == 5 && pts[4] == pts[0] { pts.removeLast() }
        guard pts.count == 4 else { return nil }
        var axis: [Bool] = []
        axis.reserveCapacity(4)
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            if a.x == b.x && a.y != b.y { axis.append(true) }
            else if a.y == b.y && a.x != b.x { axis.append(false) }
            else { return nil }
        }
        for i in 0..<4 where axis[i] == axis[(i + 1) % 4] { return nil }
        var lo = GPoint(x: Float.greatestFiniteMagnitude, y: Float.greatestFiniteMagnitude)
        var hi = GPoint(x: -Float.greatestFiniteMagnitude, y: -Float.greatestFiniteMagnitude)
        for p in pts {
            let d = ctm.transformPoint(p)
            lo.x = min(lo.x, d.x); lo.y = min(lo.y, d.y)
            hi.x = max(hi.x, d.x); hi.y = max(hi.y, d.y)
        }
        return (lo, hi)
    }

    static func op(for shape: Shape, ctm: GTransform, pen: Pen?) -> Op {
        let scale = abs(ctm.xx * ctm.yy - ctm.xy * ctm.yx).squareRoot()
        let upright = ctm.xy == 0 && ctm.yx == 0 && abs(ctm.xx) == abs(ctm.yy)
        let hw = pen.map { $0.width * scale * 0.5 } ?? 0
        switch shape {
        case .oval(let center, let radii):
            if !upright || radii.x != radii.y {
                if let p = pen, linearizes(p, scale: scale, ctm: ctm) { return .convexStroke }
                return thin(pen, scale: scale)
            }
            let c = ctm.transformPoint(center)
            let r = radii.x * scale
            return ringOp(Round(lo: GPoint(x: c.x - r, y: c.y - r), hi: GPoint(x: c.x + r, y: c.y + r), r: r), hw: pen.map { _ in hw })
        case .rounded(let lo, let hi, let r):
            if !upright { return thin(pen, scale: scale) }
            let a = ctm.transformPoint(lo), b = ctm.transformPoint(hi)
            let pLo = GPoint(x: min(a.x, b.x), y: min(a.y, b.y)), pHi = GPoint(x: max(a.x, b.x), y: max(a.y, b.y))
            if r == 0 { return rectOp((pLo, pHi), pen: pen, hw: hw, scale: scale) }
            return ringOp(Round(lo: pLo, hi: pHi, r: r * scale), hw: pen.map { _ in hw })
        case .path(let els):
            if let r = rectCorners(els, ctm: ctm) { return rectOp(r, pen: pen, hw: hw, scale: scale) }
            if let p = pen, linearizes(p, scale: scale, ctm: ctm) && GaneshConvex.closedConvex(els) { return .convexStroke }
            if let p = pen, els.count == 2, case .move(let a) = els[0], case .line(let b) = els[1] {
                if let l = lineOp(ctm.transformPoint(a), ctm.transformPoint(b), cap: p.cap, hw: hw, upright: upright) {
                    return l
                }
            }
            return thin(pen, scale: scale)
        }
    }

    private static func elementsOfPath(_ path: GPath) -> [GEl] {
        var els: [GEl] = []
        var iter = path.makeSegmentsIterator()
        while let seg = iter.next() {
            switch seg {
            case .moveTo(let a): els.append(.move(a))
            case .lineTo(let a): els.append(.line(a))
            case .quadTo(let a, let b): els.append(.quad(a, b))
            case .cubicTo(let a, let b, let c): els.append(.cubic(a, b, c))
            case .conicTo(let a, let b, let w): els.append(.conic(a, b, w))
            case .close: els.append(.close)
            }
        }
        return els
    }

    private static func pushRoundRect(_ b: inout GPathBuilder, lo: GPoint, hi: GPoint, r inR: Float) {
        let r = min(inR, min((hi.x - lo.x) * 0.5, (hi.y - lo.y) * 0.5))
        if r <= 0 {
            b.moveTo(lo.x, lo.y); b.lineTo(hi.x, lo.y); b.lineTo(hi.x, hi.y); b.lineTo(lo.x, hi.y); b.close()
            return
        }
        let w = GaneshConstants.scalarRoot2Over2
        b.moveTo(lo.x + r, lo.y)
        b.lineTo(hi.x - r, lo.y)
        b.conicTo(hi.x, lo.y, hi.x, lo.y + r, w)
        b.lineTo(hi.x, hi.y - r)
        b.conicTo(hi.x, hi.y, hi.x - r, hi.y, w)
        b.lineTo(lo.x + r, hi.y)
        b.conicTo(lo.x, hi.y, lo.x, hi.y - r, w)
        b.lineTo(lo.x, lo.y + r)
        b.conicTo(lo.x, lo.y, lo.x + r, lo.y, w)
        b.close()
    }

    private static func buildGPath(_ shape: Shape, tolerance: Float) -> GPath? {
        var b = GPathBuilder()
        b.conicTolerance = tolerance
        switch shape {
        case .path(let els):
            b.keepConics = true
            for el in els {
                switch el {
                case .move(let p): b.moveTo(p.x, p.y)
                case .line(let p): b.lineTo(p.x, p.y)
                case .quad(let c, let p): b.quadTo(c.x, c.y, p.x, p.y)
                case .cubic(let c1, let c2, let p): b.cubicTo(c1.x, c1.y, c2.x, c2.y, p.x, p.y)
                case .conic(let c, let p, let w): b.conicTo(c.x, c.y, p.x, p.y, w)
                case .close: b.close()
                }
            }
        case .oval(let center, let radii):
            guard let r = GRect.fromLTRB(center.x - radii.x, center.y - radii.y, center.x + radii.x, center.y + radii.y) else { return nil }
            b.pushOval(r)
        case .rounded(let lo, let hi, let r):
            pushRoundRect(&b, lo: lo, hi: hi, r: r)
        }
        return b.finish()
    }

    static func renderAAA(shape shapeIn: Shape, pen: Pen?, fillRule: GAAARule, ctm: GTransform, origin: GPoint, px: Int, out: inout [UInt8]) {
        for i in out.indices { out[i] = 0 }
        let res = GPathStroker.computeResolutionScale(ctm)
        guard let user = buildGPath(shapeIn, tolerance: 0.25 / res) else { return }
        let outline: GPath?
        if let p = pen {
            let stroke = GStroke(width: p.width, miterLimit: p.miterLimit, lineCap: p.cap, lineJoin: p.join)
            outline = user.stroke(stroke, resolutionScale: res)
        } else {
            outline = user
        }
        guard let outline else { return }
        let els: [GEl]
        if pen == nil, case .oval = shapeIn { els = elements(of: shapeIn) }
        else { els = elementsOfPath(outline) }
        if let dir = GaneshConvex.direction(els), dir != 0 {
            var placed = ctm
            placed.tx += origin.x
            placed.ty += origin.y
            if let mesh = GaneshConvex.fill(path: els, ctm: placed, dir: dir) {
                GaneshConvex.fillQuadEdges(mesh, origin: (origin.x, origin.y), px: px, out: &out)
            }
            return
        }
        let rule: GAAARule = (pen == nil && fillRule == .evenOdd) ? .evenOdd : .nonZero
        let fx = ctm.tx - floorf(ctm.tx), fy = ctm.ty - floorf(ctm.ty)
        let frac = GTransform(xx: ctm.xx, xy: ctm.xy, yx: ctm.yx, yy: ctm.yy, tx: fx, ty: fy)
        let b = outline.bounds
        let corners = [
            frac.transformPoint(GPoint(x: b.left, y: b.top)),
            frac.transformPoint(GPoint(x: b.right, y: b.top)),
            frac.transformPoint(GPoint(x: b.left, y: b.bottom)),
            frac.transformPoint(GPoint(x: b.right, y: b.bottom)),
        ]
        var l = Float.greatestFiniteMagnitude, t = Float.greatestFiniteMagnitude
        var r = -Float.greatestFiniteMagnitude, btm = -Float.greatestFiniteMagnitude
        for p in corners {
            l = min(l, p.x); t = min(t, p.y); r = max(r, p.x); btm = max(btm, p.y)
        }
        let dx = floorf(l), dy = floorf(t)
        let w = max(1, Int(ceilf(r) - dx) + 2), h = max(1, Int(ceilf(btm) - dy) + 2)
        let pad: Float = 1.0
        guard let device = outline.transform(frac.postTranslate(pad - dx, pad - dy)) else { return }
        var mask = [UInt8](repeating: 0, count: w * h)
        GaneshAAA.fill(path: device, rule: rule, width: w, height: h, out: &mask)
        let ox = Int(floorf(ctm.tx) + dx - pad)
        let oy = Int(floorf(ctm.ty) + dy - pad)
        for y in 0..<h {
            let cy = oy + y
            guard cy >= 0 && cy < px else { continue }
            for x in 0..<w {
                let cx = ox + x
                guard cx >= 0 && cx < px else { continue }
                out[cy * px + cx] = mask[y * w + x]
            }
        }
    }
}

// MARK: - Icon Coverage Rasterizer (`icon.rs`)

internal enum GaneshIcon {
    private static let inheritedAttrs: Set<String> = [
        "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
        "stroke-miterlimit", "fill-rule", "fill-opacity", "stroke-opacity"
    ]
    private static let nonRenderingTags: Set<String> = [
        "defs", "clipPath", "mask", "symbol", "linearGradient", "radialGradient",
        "pattern", "marker", "filter", "title", "desc", "style"
    ]

    private struct Scope {
        var ctm: GTransform
        var paints: Bool
        var group: String?
        var layer: Bool
    }

    private static func attr(_ el: String, _ name: String) -> String? {
        var rest = el[...]
        while let range = rest.range(of: name) {
            let before = range.lowerBound > rest.startIndex ? rest[rest.index(before: range.lowerBound)] : nil
            let after = rest[range.upperBound...]
            if before?.isWhitespace == true && after.hasPrefix("=\"") {
                let v = after.dropFirst(2)
                if let q = v.firstIndex(of: "\"") {
                    return String(v[..<q])
                }
                return nil
            }
            // Also check single quotes for Swift bodies that might use single quotes.
            if before?.isWhitespace == true && after.hasPrefix("='") {
                let v = after.dropFirst(2)
                if let q = v.firstIndex(of: "'") {
                    return String(v[..<q])
                }
                return nil
            }
            rest = rest[range.upperBound...]
        }
        return nil
    }

    private static func num(_ el: String, _ name: String) -> Float {
        guard let v = attr(el, name) else { return 0 }
        let trimmed = v.hasSuffix("px") ? String(v.dropLast(2)) : v
        return Float(trimmed) ?? 0
    }

    private static func opacity(_ v: String?) -> Float {
        guard let raw = v?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 1.0 }
        let n: Float?
        if raw.hasSuffix("%") {
            n = Float(raw.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 / 100.0 }
        } else {
            n = Float(raw)
        }
        return gBound(n ?? 1.0, 0, 1)
    }

    private static func numbers(_ s: String) -> [Float] {
        var out: [Float] = []
        var cur = ""
        var prev: Character = " "
        for c in s {
            let starts = (c == "-" || c == "+") && prev != "e" && prev != "E"
            if c == "," || c.isWhitespace || (starts && !cur.isEmpty) {
                if let v = Float(cur) { out.append(v) }
                cur.removeAll(keepingCapacity: true)
            }
            if !(c == "," || c.isWhitespace) { cur.append(c) }
            prev = c
        }
        if let v = Float(cur) { out.append(v) }
        return out
    }

    private static func parseTransform(_ list: String) -> GTransform {
        var m = GTransform.identity
        for item in list.split(separator: ")") {
            guard let paren = item.firstIndex(of: "(") else { continue }
            var name = String(item[..<paren]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix(",") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
            let a = numbers(String(item[item.index(after: paren)...]))
            @inline(__always) func at(_ i: Int) -> Float { i < a.count ? a[i] : 0 }
            let t: GTransform
            switch name {
            case "matrix" where a.count == 6:
                t = GTransform(xx: a[0], xy: a[1], yx: a[2], yy: a[3], tx: a[4], ty: a[5])
            case "translate":
                t = .translation(at(0), at(1))
            case "scale":
                t = .scale(at(0), a.count > 1 ? a[1] : at(0))
            case "rotate":
                let rad = Double(at(0)) * Double.pi / 180.0
                let sinV = sin(rad), cosV = cos(rad)
                let cx = Double(at(1)), cy = Double(at(2))
                let tx = cx - cosV * cx + sinV * cy
                let ty = cy - sinV * cx - cosV * cy
                t = GTransform(xx: Float(cosV), xy: Float(sinV), yx: Float(-sinV), yy: Float(cosV), tx: Float(tx), ty: Float(ty))
            case "skewX":
                t = GTransform(xx: 1, xy: 0, yx: tanf(at(0) * Float.pi / 180.0), yy: 1, tx: 0, ty: 0)
            case "skewY":
                t = GTransform(xx: 1, xy: tanf(at(0) * Float.pi / 180.0), yx: 0, yy: 1, tx: 0, ty: 0)
            default:
                continue
            }
            m = GTransform.then(t, m)
        }
        return m
    }

    private static func elementPath(_ el: String) -> String? {
        let stripped = el.drop(while: { $0 == "<" })
        guard let tag = stripped.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) else { return nil }
        switch tag {
        case "path":
            return attr(el, "d")
        case "rect":
            let x = num(el, "x"), y = num(el, "y"), w = num(el, "width"), h = num(el, "height")
            let r = min(num(el, "rx"), min(w * 0.5, h * 0.5))
            if r <= 0 {
                return "M\(x) \(y)h\(w)v\(h)h\(-w)Z"
            }
            return "M\(x + r) \(y)h\(w - 2.0 * r)a\(r) \(r) 0 0 1 \(r) \(r)v\(h - 2.0 * r)a\(r) \(r) 0 0 1 \(-r) \(r)h\(-(w - 2.0 * r))a\(r) \(r) 0 0 1 \(-r) \(-r)v\(-(h - 2.0 * r))a\(r) \(r) 0 0 1 \(r) \(-r)Z"
        case "circle", "ellipse":
            let cx = num(el, "cx"), cy = num(el, "cy")
            let rx = tag == "circle" ? num(el, "r") : num(el, "rx")
            let ry = tag == "circle" ? num(el, "r") : num(el, "ry")
            return "M\(cx - rx) \(cy)a\(rx) \(ry) 0 1 0 \(2.0 * rx) 0a\(rx) \(ry) 0 1 0 \(-2.0 * rx) 0Z"
        case "line":
            return "M\(num(el, "x1")) \(num(el, "y1"))L\(num(el, "x2")) \(num(el, "y2"))"
        case "polyline", "polygon":
            guard let ptsAttr = attr(el, "points") else { return nil }
            let p = numbers(ptsAttr)
            var d = ""
            let pairCount = p.count / 2
            for i in 0..<pairCount {
                d += "\(i == 0 ? "M" : "L")\(p[i * 2]) \(p[i * 2 + 1])"
            }
            if tag == "polygon" { d += "Z" }
            return d
        default:
            return nil
        }
    }

    private static func elementShape(_ el: String) -> GaneshArea.Shape? {
        let stripped = el.drop(while: { $0 == "<" })
        guard let tag = stripped.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) else { return nil }
        switch tag {
        case "circle":
            let r = num(el, "r")
            return .oval(center: GPoint(x: num(el, "cx"), y: num(el, "cy")), radii: GPoint(x: r, y: r))
        case "ellipse":
            return .oval(center: GPoint(x: num(el, "cx"), y: num(el, "cy")), radii: GPoint(x: num(el, "rx"), y: num(el, "ry")))
        case "rect":
            let x = num(el, "x"), y = num(el, "y"), w = num(el, "width"), h = num(el, "height")
            let r = min(num(el, "rx"), min(w * 0.5, h * 0.5))
            let ry = attr(el, "ry") != nil ? min(num(el, "ry"), h * 0.5) : r
            if r == 0 || ry == r {
                return .rounded(lo: GPoint(x: x, y: y), hi: GPoint(x: x + w, y: y + h), r: max(0, r))
            }
            return nil
        default:
            return nil
        }
    }

    private static func union(_ acc: inout [UInt8], _ top: [UInt8], alpha: Float) {
        for i in acc.indices {
            let fa = UInt32(acc[i])
            let fb = UInt32((Float(top[i]) * alpha).rounded())
            acc[i] = UInt8(min(255, fa + fb - (fa * fb) / 255))
        }
    }

    private static func paintShape(
        _ shape: GaneshArea.Shape,
        ctm: GTransform,
        origin: GPoint,
        pen: GaneshArea.Pen?,
        fill: GAAARule,
        alpha: Float,
        px: Int,
        buf: inout [UInt8],
        into: inout [UInt8]
    ) {
        let op = GaneshArea.op(for: shape, ctm: ctm, pen: pen)
        switch op {
        case .hairline(let width):
            var placed = ctm
            placed.tx += origin.x
            placed.ty += origin.y
            GaneshConvex.hairline(path: GaneshArea.elements(of: shape), ctm: placed, width: width, origin: (origin.x, origin.y), px: px, out: &buf)
        case .path:
            GaneshArea.renderAAA(shape: shape, pen: pen, fillRule: fill, ctm: ctm, origin: origin, px: px, out: &buf)
        case .convexStroke:
            var placed = ctm
            placed.tx += origin.x
            placed.ty += origin.y
            if let p = pen, let mesh = GaneshConvex.stroke(path: GaneshArea.elements(of: shape), ctm: placed, width: p.width, join: p.join, miterLimit: p.miterLimit) {
                GaneshConvex.fillTriangles(mesh, origin: (origin.x, origin.y), px: px, out: &buf)
            } else {
                GaneshArea.renderAAA(shape: shape, pen: pen, fillRule: fill, ctm: ctm, origin: origin, px: px, out: &buf)
            }
        case .rect, .strokeRect, .quad, .round:
            op.render(px: px, out: &buf)
        }
        union(&into, buf, alpha: alpha)
    }

    static func coverageAt(_ icon: SVGIcon, pixelSize px: Int, drawnSize: Float? = nil, origin: GPoint = .zero) -> [UInt8] {
        guard px > 0 else { return [] }
        let size = drawnSize ?? Float(px)
        let s = size / max(Float(1), icon.viewBox)
        let count = px * px
        var acc = [UInt8](repeating: 0, count: count)
        var buf = [UInt8](repeating: 0, count: count)

        guard let body = icon.body else {
            let ctm = GTransform.scale(s, s)
            let pen: GaneshArea.Pen? = icon.strokeWidth.flatMap { sw in
                sw > 0 ? GaneshArea.Pen(width: sw, cap: .round, join: .round, miterLimit: 4.0) : nil
            }
            for d in icon.paths {
                let els = GSVGPathParser.parse(d)
                paintShape(.path(els), ctm: ctm, origin: origin, pen: pen, fill: .nonZero, alpha: 1.0, px: px, buf: &buf, into: &acc)
            }
            return acc
        }

        var layers: [([UInt8], Float)] = []
        let root = Scope(ctm: .scale(s, s), paints: true, group: nil, layer: false)
        var scopes: [Scope] = []

        @inline(__always)
        func unionToCurrent(_ top: [UInt8], _ alpha: Float) {
            if layers.isEmpty {
                union(&acc, top, alpha: alpha)
            } else {
                let last = layers.count - 1
                union(&layers[last].0, top, alpha: alpha)
            }
        }

        @inline(__always)
        func paintIntoCurrent(_ shape: GaneshArea.Shape, _ ctm: GTransform, _ pen: GaneshArea.Pen?, _ fill: GAAARule, _ alpha: Float) {
            if layers.isEmpty {
                paintShape(shape, ctm: ctm, origin: origin, pen: pen, fill: fill, alpha: alpha, px: px, buf: &buf, into: &acc)
            } else {
                let last = layers.count - 1
                var dst = layers[last].0
                paintShape(shape, ctm: ctm, origin: origin, pen: pen, fill: fill, alpha: alpha, px: px, buf: &buf, into: &dst)
                layers[last].0 = dst
            }
        }

        for raw in body.split(separator: ">") {
            let el = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if el.isEmpty || el.hasPrefix("<!") || el.hasPrefix("<?") { continue }
            if el.hasPrefix("</") {
                if let sc = scopes.popLast(), sc.layer, let (top, alpha) = layers.popLast() {
                    unionToCurrent(top, alpha)
                }
                continue
            }
            let stripped = el.drop(while: { $0 == "<" })
            var tag = stripped.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            if tag.hasSuffix("/") { tag.removeLast() }
            let open = !el.hasSuffix("/")
            let up = scopes.last ?? root
            let ctm = attr(el, "transform").map { GTransform.then(parseTransform($0), up.ctm) } ?? up.ctm
            let paints = up.paints && attr(el, "display") != "none" && !nonRenderingTags.contains(tag)
            if tag == "g" || tag == "a" || tag == "svg" {
                if open {
                    let alpha = opacity(attr(el, "opacity"))
                    let layer = paints && alpha < 1.0
                    if layer { layers.append(([UInt8](repeating: 0, count: count), alpha)) }
                    scopes.append(Scope(ctm: ctm, paints: paints, group: el, layer: layer))
                }
                continue
            }
            if open {
                scopes.append(Scope(ctm: ctm, paints: false, group: nil, layer: false))
            }
            if !paints { continue }
            guard let pathD = elementPath(el) else { continue }
            let els = GSVGPathParser.parse(pathD)

            func get(_ name: String) -> String? {
                if let direct = attr(el, name) { return direct }
                guard inheritedAttrs.contains(name) else { return nil }
                for sc in scopes.reversed() {
                    if let g = sc.group, let v = attr(g, name) { return v }
                }
                return nil
            }

            let hasStroke = get("stroke").map { $0 != "none" } ?? false
            let hasFill = get("fill").map { $0 != "none" } ?? !hasStroke
            let whole = opacity(attr(el, "opacity"))
            let shape = elementShape(el) ?? .path(els)

            if hasFill {
                let rule: GAAARule = get("fill-rule") == "evenodd" ? .evenOdd : .nonZero
                paintIntoCurrent(shape, ctm, nil, rule, whole * opacity(get("fill-opacity")))
            }
            if hasStroke {
                let wStr = get("stroke-width")
                let w: Float = wStr.flatMap {
                    let s = $0.hasSuffix("px") ? String($0.dropLast(2)) : $0
                    return Float(s)
                } ?? 1.0
                let cap: GLineCap
                switch get("stroke-linecap") {
                case "round": cap = .round
                case "square": cap = .square
                default: cap = .butt
                }
                let join: GLineJoin
                switch get("stroke-linejoin") {
                case "round": join = .round
                case "bevel": join = .bevel
                default: join = .miter
                }
                let miterLimit = get("stroke-miterlimit").flatMap { Float($0) } ?? 4.0
                let pen = GaneshArea.Pen(width: w, cap: cap, join: join, miterLimit: miterLimit)
                paintIntoCurrent(shape, ctm, pen, .nonZero, whole * opacity(get("stroke-opacity")))
            }
        }
        while let (top, alpha) = layers.popLast() {
            unionToCurrent(top, alpha)
        }
        return acc
    }
}
