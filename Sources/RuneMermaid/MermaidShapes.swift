import Foundation
import Rune

enum NodeShape: Equatable, Hashable {
    case rect
    case round
    case stadium
    case subroutine
    case cylinder
    case circle
    case doubleCircle
    case asymmetric
    case diamond
    case hexagon
    case leanRight
    case leanLeft
    case trapBottom
    case trapTop
    case smallCircle
    case filledCircle
    case framedCircle
    case crossedCircle
    case bang
    case cloud
    case card
    case hourglass
    case bolt
    case braceLeft
    case braceRight
    case braces
    case delay
    case hCylinder
    case linedCylinder
    case curvedTrapezoid
    case dividedRect
    case document
    case linedDocument
    case documents
    case taggedDocument
    case triangle
    case flippedTriangle
    case fork
    case windowPane
    case linedRect
    case notchedPentagon
    case slopedRect
    case stackedRect
    case flag
    case bowRect
    case taggedRect
    case text
    case note

    static func named(_ name: String) -> NodeShape? {
        switch name {
        case "rect", "proc", "process", "rectangle", "icon", "image": .rect
        case "rounded", "event": .round
        case "stadium", "pill", "terminal": .stadium
        case "fr-rect", "framed-rectangle", "subproc", "subprocess", "subroutine": .subroutine
        case "cyl", "cylinder", "database", "db": .cylinder
        case "circle", "circ": .circle
        case "dbl-circ", "double-circle": .doubleCircle
        case "odd": .asymmetric
        case "diam", "decision", "diamond", "question": .diamond
        case "hex", "hexagon", "prepare": .hexagon
        case "lean-r", "lean-right", "in-out": .leanRight
        case "lean-l", "lean-left", "out-in": .leanLeft
        case "trap-b", "priority", "trapezoid", "trapezoid-bottom": .trapBottom
        case "trap-t", "inv-trapezoid", "manual", "trapezoid-top": .trapTop
        case "sm-circ", "small-circle", "start": .smallCircle
        case "f-circ", "filled-circle", "junction": .filledCircle
        case "fr-circ", "framed-circle", "stop": .framedCircle
        case "cross-circ", "crossed-circle", "summary": .crossedCircle
        case "bang": .bang
        case "cloud": .cloud
        case "notch-rect", "card", "notched-rectangle": .card
        case "hourglass", "collate": .hourglass
        case "bolt", "com-link", "lightning-bolt": .bolt
        case "brace", "brace-l", "comment": .braceLeft
        case "brace-r": .braceRight
        case "braces": .braces
        case "delay", "half-rounded-rectangle": .delay
        case "h-cyl", "das", "horizontal-cylinder": .hCylinder
        case "lin-cyl", "disk", "lined-cylinder": .linedCylinder
        case "curv-trap", "curved-trapezoid", "display": .curvedTrapezoid
        case "div-rect", "div-proc", "divided-process", "divided-rectangle": .dividedRect
        case "doc", "document": .document
        case "lin-doc", "lined-document": .linedDocument
        case "docs", "documents", "st-doc", "stacked-document": .documents
        case "tag-doc", "tagged-document": .taggedDocument
        case "tri", "extract", "triangle": .triangle
        case "flip-tri", "flipped-triangle", "manual-file": .flippedTriangle
        case "fork", "join": .fork
        case "win-pane", "internal-storage", "window-pane": .windowPane
        case "lin-rect", "lin-proc", "lined-process", "lined-rectangle", "shaded-process": .linedRect
        case "notch-pent", "loop-limit", "notched-pentagon": .notchedPentagon
        case "sl-rect", "manual-input", "sloped-rectangle": .slopedRect
        case "st-rect", "processes", "procs", "stacked-rectangle": .stackedRect
        case "flag", "paper-tape": .flag
        case "bow-rect", "bow-tie-rectangle", "stored-data": .bowRect
        case "tag-rect", "tag-proc", "tagged-process", "tagged-rectangle": .taggedRect
        case "text": .text
        default: nil
        }
    }

    var isUnlabelled: Bool {
        switch self {
        case .smallCircle, .filledCircle, .framedCircle, .crossedCircle, .fork: true
        default: false
        }
    }

    var isFlat: Bool {
        switch self {
        case .stadium, .cylinder, .circle, .doubleCircle, .diamond, .hexagon,
             .leanRight, .leanLeft, .trapBottom, .trapTop, .smallCircle,
             .filledCircle, .framedCircle, .crossedCircle, .bang, .cloud,
             .linedCylinder, .triangle, .flippedTriangle:
            return false
        default:
            return true
        }
    }
}

enum ShapeRenderer {
    private static let pad = Vec2(30.0, 22.0)
    private static let glyph: Float = 32.0
    private static let stack: Float = 5.0
    private static let linedOffset: Float = 6.0

    static func nodeSize(_ shape: NodeShape, labelSize t: Vec2) -> Vec2 {
        let w = t.x + pad.x
        let h = max(t.y + pad.y, 40.0)
        let rectW = max(w, 60.0)
        switch shape {
        case .rect, .round, .taggedRect, .note:
            return Vec2(rectW, h)
        case .stadium, .hexagon:
            return Vec2(w + h * 0.5, h)
        case .subroutine, .linedRect, .card:
            return Vec2(w + 16.0, h)
        case .asymmetric:
            return Vec2(w + h / 3.0, h)
        case .cylinder:
            return Vec2(rectW, h + 3.0 * rim(rectW))
        case .linedCylinder:
            return Vec2(rectW, h + 3.0 * rim(rectW) + linedOffset)
        case .hCylinder:
            return Vec2(w + 24.0, h)
        case .leanRight, .leanLeft, .trapBottom, .trapTop:
            return Vec2(w + h * 0.6, h)
        case .circle:
            return circleSize(t, pad: 20.0)
        case .doubleCircle:
            return circleSize(t, pad: 30.0)
        case .diamond:
            let a = t.x * 0.5 + t.y + 12.0
            let b = t.y * 0.5 * a / (t.y + 12.0) + 10.0
            return Vec2(2.0 * a, max(2.0 * b, 40.0))
        case .smallCircle, .filledCircle:
            return Vec2(14.0, 14.0)
        case .framedCircle:
            return Vec2(20.0, 20.0)
        case .crossedCircle:
            return Vec2(30.0, 30.0)
        case .fork:
            return Vec2(70.0, 10.0)
        case .bang:
            return Vec2(w * 1.5, h * 1.7)
        case .cloud:
            return Vec2(w * 1.35, h * 1.55)
        case .hourglass, .bolt:
            return Vec2(max(t.x, glyph), t.y > 0 ? glyph + 6.0 + t.y : glyph)
        case .braceLeft, .braceRight:
            return Vec2(w + 6.0, h)
        case .braces:
            return Vec2(w + 18.0, h)
        case .delay, .curvedTrapezoid, .bowRect:
            return Vec2(w + h * 0.5, h)
        case .dividedRect:
            return Vec2(rectW, h + 10.0)
        case .document, .linedDocument, .taggedDocument, .flag, .slopedRect:
            return Vec2(rectW + 8.0, h + 12.0)
        case .documents:
            return Vec2(rectW + 8.0 + 2.0 * stack, h + 12.0 + 2.0 * stack)
        case .stackedRect:
            return Vec2(rectW + 2.0 * stack, h + 2.0 * stack)
        case .triangle, .flippedTriangle:
            let tw = 1.6 * (t.x + 16.0)
            return Vec2(max(tw, 60.0), max(0.7 * tw, 3.0 * t.y + 16.0))
        case .windowPane:
            return Vec2(rectW + 10.0, h + 10.0)
        case .notchedPentagon:
            return Vec2(w + 24.0, h)
        case .text:
            return Vec2(t.x + 12.0, t.y + 12.0)
        }
    }

    static func rim(_ w: Float) -> Float {
        w / 2.0 / (2.5 + w / 50.0)
    }

    private static func circleSize(_ t: Vec2, pad: Float) -> Vec2 {
        let d = max(hypotf(t.x, t.y) + pad, 48.0)
        return Vec2(d, d)
    }

    static func boundary(shape: NodeShape, center c: Vec2, size: Vec2, toward: Vec2) -> Vec2 {
        let dx = toward.x - c.x
        let dy = toward.y - c.y
        if abs(dx) < 1e-3 && abs(dy) < 1e-3 { return c }
        let a = size.x * 0.5
        let b = size.y * 0.5
        func rectT() -> Float {
            let tx = abs(dx) > 1e-3 ? a / abs(dx) : Float.greatestFiniteMagnitude
            let ty = abs(dy) > 1e-3 ? b / abs(dy) : Float.greatestFiniteMagnitude
            return min(tx, ty)
        }
        let t: Float
        switch shape {
        case .circle, .doubleCircle, .smallCircle, .filledCircle, .framedCircle, .crossedCircle:
            t = 1.0 / hypotf(dx / a, dy / b)
        case .diamond:
            t = 1.0 / (abs(dx) / a + abs(dy) / b)
        case .rect, .round, .subroutine, .asymmetric, .stadium, .hexagon, .cylinder,
             .leanRight, .leanLeft, .trapBottom, .trapTop, .hourglass, .bolt,
             .braceLeft, .braceRight, .braces, .text:
            t = rectT()
        default:
            t = rayExit(poly: outline(shape: shape, center: c, size: size), center: c, dir: Vec2(dx, dy)) ?? rectT()
        }
        let clamped = min(t, 1.0)
        return Vec2(c.x + dx * clamped, c.y + dy * clamped)
    }

    private static func rayExit(poly: [Vec2], center c: Vec2, dir d: Vec2) -> Float? {
        guard !poly.isEmpty else { return nil }
        var best: Float? = nil
        for i in 0..<poly.count {
            let p = poly[i]
            let q = poly[(i + 1) % poly.count]
            let e = Vec2(q.x - p.x, q.y - p.y)
            let den = d.x * e.y - d.y * e.x
            if abs(den) < 1e-9 { continue }
            let w = Vec2(p.x - c.x, p.y - c.y)
            let t = (w.x * e.y - w.y * e.x) / den
            let u = (w.x * d.y - w.y * d.x) / den
            if t > 0.0 && (0.0...1.0).contains(u) {
                if let b = best {
                    if t > b { best = t }
                } else {
                    best = t
                }
            }
        }
        return best
    }

    private static func bounds(_ c: Vec2, _ s: Vec2) -> (Float, Float, Float, Float) {
        (c.x - s.x * 0.5, c.y - s.y * 0.5, c.x + s.x * 0.5, c.y + s.y * 0.5)
    }

    private static func rectPts(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [Vec2] {
        [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
    }

    private static func wave(x0: Float, x1: Float, y: Float, amp: Float) -> [Vec2] {
        let n = 24
        return (0...n).map { i in
            let f = Float(i) / Float(n)
            return Vec2(x0 + (x1 - x0) * f, y + amp * sinf(f * Float.pi * 2.0 * 1.5))
        }
    }

    private static func quad(_ a: Vec2, _ k: Vec2, _ b: Vec2) -> [Vec2] {
        (0...8).map { i in
            let t = Float(i) / 8.0
            let m = 1.0 - t
            return Vec2(
                m * m * a.x + 2.0 * m * t * k.x + t * t * b.x,
                m * m * a.y + 2.0 * m * t * k.y + t * t * b.y
            )
        }
    }

    private static func brace(x: Float, y0: Float, y1: Float, side: Float) -> [Vec2] {
        let r: Float = 6.0
        let cy = (y0 + y1) * 0.5
        var p = quad(Vec2(x - side * r, y0), Vec2(x, y0), Vec2(x, y0 + r))
        p.append(contentsOf: quad(Vec2(x, cy - r), Vec2(x, cy), Vec2(x + side * r, cy)))
        p.append(contentsOf: quad(Vec2(x + side * r, cy), Vec2(x, cy), Vec2(x, cy + r)))
        p.append(contentsOf: quad(Vec2(x, y1 - r), Vec2(x, y1), Vec2(x - side * r, y1)))
        return p
    }

    private static func documentPts(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [Vec2] {
        var p = [Vec2(x0, y0), Vec2(x1, y0)]
        p.append(contentsOf: wave(x0: x1, x1: x0, y: y1 - 6.0, amp: 5.0))
        return p
    }

    private static func glyphBox(_ c: Vec2, _ s: Vec2) -> (Float, Float, Float, Float) {
        let y0 = c.y - s.y * 0.5
        return (c.x - glyph * 0.5, y0, c.x + glyph * 0.5, y0 + glyph)
    }

    static func outline(shape: NodeShape, center c: Vec2, size s: Vec2) -> [Vec2] {
        let (x0, y0, x1, y1) = bounds(c, s)
        let h = s.y
        let cy = c.y
        switch shape {
        case .rect, .subroutine, .dividedRect, .linedRect, .windowPane, .taggedRect:
            return CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: 3.0)
        case .round:
            return CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: 10.0)
        case .stadium:
            return CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: h * 0.5)
        case .circle, .doubleCircle, .smallCircle, .filledCircle, .framedCircle, .crossedCircle:
            return CanvasMath.ellipse(center: c, rx: s.x * 0.5, ry: s.y * 0.5)
        case .diamond:
            return [Vec2(c.x, y0), Vec2(x1, cy), Vec2(c.x, y1), Vec2(x0, cy)]
        case .hexagon:
            let i = h / 4.0
            return [Vec2(x0 + i, y0), Vec2(x1 - i, y0), Vec2(x1, cy), Vec2(x1 - i, y1), Vec2(x0 + i, y1), Vec2(x0, cy)]
        case .asymmetric:
            return [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1), Vec2(x0 + h / 3.0, cy)]
        case .leanRight:
            return [Vec2(x0 + h * 0.3, y0), Vec2(x1, y0), Vec2(x1 - h * 0.3, y1), Vec2(x0, y1)]
        case .leanLeft:
            return [Vec2(x0, y0), Vec2(x1 - h * 0.3, y0), Vec2(x1, y1), Vec2(x0 + h * 0.3, y1)]
        case .trapBottom:
            return [Vec2(x0 + h * 0.3, y0), Vec2(x1 - h * 0.3, y0), Vec2(x1, y1), Vec2(x0, y1)]
        case .trapTop:
            return [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1 - h * 0.3, y1), Vec2(x0 + h * 0.3, y1)]
        case .cylinder, .linedCylinder:
            let rx = s.x * 0.5
            let ry = rim(s.x)
            var pts = CanvasMath.arc(center: Vec2(c.x, y0 + ry), rx: rx, ry: ry, a0: 180.0, a1: 360.0, steps: 20)
            pts.append(contentsOf: CanvasMath.arc(center: Vec2(c.x, y1 - ry), rx: rx, ry: ry, a0: 0.0, a1: 180.0, steps: 20))
            return pts
        case .hCylinder:
            let rx: Float = 8.0
            let ry = h * 0.5
            var pts = CanvasMath.arc(center: Vec2(x1 - rx, cy), rx: rx, ry: ry, a0: -90.0, a1: 90.0, steps: 20)
            pts.append(contentsOf: CanvasMath.arc(center: Vec2(x0 + rx, cy), rx: rx, ry: ry, a0: 90.0, a1: 270.0, steps: 20))
            return pts
        case .bang:
            return (0..<28).map { i in
                let a = (Float(i) * 360.0 / 28.0) * (.pi / 180.0)
                let r: Float = i % 2 == 0 ? 1.0 : 0.8
                return Vec2(c.x + s.x * 0.5 * r * cosf(a), cy + s.y * 0.5 * r * sinf(a))
            }
        case .cloud:
            return (0..<120).map { i in
                let a = (Float(i) * 3.0) * (.pi / 180.0)
                let r = 0.84 + 0.16 * sqrtf(abs(sinf(5.0 * a)))
                return Vec2(c.x + s.x * 0.5 * r * cosf(a), cy + s.y * 0.5 * r * sinf(a))
            }
        case .card:
            return [Vec2(x0 + 12.0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1), Vec2(x0, y0 + 12.0)]
        case .note:
            return [Vec2(x0, y0), Vec2(x1 - 10.0, y0), Vec2(x1, y0 + 10.0), Vec2(x1, y1), Vec2(x0, y1)]
        case .notchedPentagon:
            return [Vec2(x0 + 12.0, y0), Vec2(x1 - 12.0, y0), Vec2(x1, y0 + 12.0), Vec2(x1, y1), Vec2(x0, y1), Vec2(x0, y0 + 12.0)]
        case .slopedRect:
            return [Vec2(x0, y0 + 12.0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
        case .delay:
            var p = [Vec2(x0, y0)]
            p.append(contentsOf: CanvasMath.arc(center: Vec2(x1 - h * 0.5, cy), rx: h * 0.5, ry: h * 0.5, a0: -90.0, a1: 90.0, steps: 16))
            p.append(Vec2(x0, y1))
            return p
        case .curvedTrapezoid:
            let k = h / 4.0
            var p = [Vec2(x0 + k, y0)]
            p.append(contentsOf: CanvasMath.arc(center: Vec2(x1 - h * 0.5, cy), rx: h * 0.5, ry: h * 0.5, a0: -90.0, a1: 90.0, steps: 16))
            p.append(contentsOf: quad(Vec2(x0 + k, y1), Vec2(x0, y1), Vec2(x0, cy)))
            p.append(contentsOf: quad(Vec2(x0, cy), Vec2(x0, y0), Vec2(x0 + k, y0)))
            return p
        case .bowRect:
            let rx = h / 4.0
            var p = CanvasMath.arc(center: Vec2(x1, cy), rx: rx, ry: h * 0.5, a0: 270.0, a1: 90.0, steps: 16)
            p.append(contentsOf: CanvasMath.arc(center: Vec2(x0 + rx, cy), rx: rx, ry: h * 0.5, a0: 90.0, a1: 270.0, steps: 16))
            return p
        case .document, .linedDocument, .taggedDocument:
            return documentPts(x0, y0, x1, y1)
        case .documents:
            return documentPts(x0, y0 + 2.0 * stack, x1 - 2.0 * stack, y1)
        case .stackedRect:
            return rectPts(x0, y0 + 2.0 * stack, x1 - 2.0 * stack, y1)
        case .flag:
            var p = wave(x0: x0, x1: x1, y: y0 + 6.0, amp: 5.0)
            p.append(contentsOf: wave(x0: x1, x1: x0, y: y1 - 6.0, amp: 5.0))
            return p
        case .triangle:
            return [Vec2(c.x, y0), Vec2(x1, y1), Vec2(x0, y1)]
        case .flippedTriangle:
            return [Vec2(x0, y0), Vec2(x1, y0), Vec2(c.x, y1)]
        case .fork:
            return CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: 2.0)
        case .hourglass, .bolt, .braceLeft, .braceRight, .braces, .text:
            return rectPts(x0, y0, x1, y1)
        }
    }

    private static func lid(_ fill: Color, _ paint: MermaidTheme) -> Color {
        overColor(paint.text.alpha(0.06), fill)
    }

    static func draw(
        into c: inout Canvas,
        shape: NodeShape,
        label: Measured,
        center ctr: Vec2,
        size: Vec2,
        colors: (fill: Color, border: Color, text: Color),
        paint: MermaidTheme
    ) {
        let (x0, y0, x1, y1) = bounds(ctr, size)
        let h = size.y
        let (fill, border, textColor) = colors
        var at = ctr

        func line(_ pts: [Vec2]) {
            c.stroke(pts, closed: false, width: 1.0, color: border)
        }

        switch shape {
        case .text:
            break
        case .braceLeft:
            c.stroke(brace(x: x0 + 6.0, y0: y0 + 2.0, y1: y1 - 2.0, side: -1.0), closed: false, width: 1.25, color: border)
            at.x += 3.0
        case .braceRight:
            c.stroke(brace(x: x1 - 6.0, y0: y0 + 2.0, y1: y1 - 2.0, side: 1.0), closed: false, width: 1.25, color: border)
            at.x -= 3.0
        case .braces:
            c.stroke(brace(x: x0 + 6.0, y0: y0 + 2.0, y1: y1 - 2.0, side: -1.0), closed: false, width: 1.25, color: border)
            c.stroke(brace(x: x1 - 6.0, y0: y0 + 2.0, y1: y1 - 2.0, side: 1.0), closed: false, width: 1.25, color: border)
        case .filledCircle, .fork:
            c.fill(outline(shape: shape, center: ctr, size: size), color: paint.line)
        case .framedCircle:
            c.shape(outline(shape: shape, center: ctr, size: size), fill: fill, border: paint.line, width: 1.5)
            c.fill(CanvasMath.ellipse(center: ctr, rx: 5.5, ry: 5.5), color: paint.line)
        case .hourglass:
            let (g0, gy0, g1, gy1) = glyphBox(ctr, size)
            let mid = Vec2(ctr.x, (gy0 + gy1) * 0.5)
            c.shape([Vec2(g0, gy0), Vec2(g1, gy0), mid, Vec2(g1, gy1), Vec2(g0, gy1), mid], fill: fill, border: border, width: 1.0)
            at.y = gy1 + 6.0 + label.size.y * 0.5
        case .bolt:
            let (g0, gy0, _, _) = glyphBox(ctr, size)
            func p(_ x: Float, _ y: Float) -> Vec2 { Vec2(g0 + x * glyph, gy0 + y * glyph) }
            c.shape([p(0.6, 0.0), p(0.15, 0.58), p(0.45, 0.58), p(0.35, 1.0), p(0.85, 0.4), p(0.55, 0.4), p(0.75, 0.0)], fill: fill, border: border, width: 1.0)
            at.y = gy0 + glyph + 6.0 + label.size.y * 0.5
        case .documents:
            for k: Float in [2.0, 1.0] {
                let d = k * stack
                c.shape(documentPts(x0 + d, y0 + 2.0 * stack - d, x1 - 2.0 * stack + d, y1 - d), fill: fill, border: border, width: 1.0)
            }
            c.shape(outline(shape: shape, center: ctr, size: size), fill: fill, border: border, width: 1.0)
            at = Vec2(ctr.x - stack, ctr.y + stack - 3.0)
        case .stackedRect:
            for k: Float in [2.0, 1.0] {
                let d = k * stack
                c.shape(rectPts(x0 + d, y0 + 2.0 * stack - d, x1 - 2.0 * stack + d, y1 - d), fill: fill, border: border, width: 1.0)
            }
            c.shape(outline(shape: shape, center: ctr, size: size), fill: fill, border: border, width: 1.0)
            at = Vec2(ctr.x - stack, ctr.y + stack)
        case .note:
            c.shape(outline(shape: shape, center: ctr, size: size), fill: paint.noteFill, border: paint.noteBorder, width: 1.0)
            c.stroke([Vec2(x1 - 10.0, y0), Vec2(x1 - 10.0, y0 + 10.0), Vec2(x1, y0 + 10.0)], closed: false, width: 1.0, color: paint.noteBorder)
        default:
            c.shape(outline(shape: shape, center: ctr, size: size), fill: fill, border: border, width: 1.0)
            switch shape {
            case .subroutine:
                line([Vec2(x0 + 8.0, y0), Vec2(x0 + 8.0, y1)])
                line([Vec2(x1 - 8.0, y0), Vec2(x1 - 8.0, y1)])
            case .cylinder:
                let ry = rim(size.x)
                c.shape(CanvasMath.ellipse(center: Vec2(ctr.x, y0 + ry), rx: size.x * 0.5, ry: ry), fill: lid(fill, paint), border: border, width: 1.0)
                at.y += ry * 0.5
            case .linedCylinder:
                let ry = rim(size.x)
                c.shape(CanvasMath.ellipse(center: Vec2(ctr.x, y0 + ry), rx: size.x * 0.5, ry: ry), fill: lid(fill, paint), border: border, width: 1.0)
                line(CanvasMath.arc(center: Vec2(ctr.x, y0 + ry + linedOffset), rx: size.x * 0.5, ry: ry, a0: 0.0, a1: 180.0, steps: 24))
                at.y += (ry + linedOffset) * 0.5
            case .hCylinder:
                c.shape(CanvasMath.ellipse(center: Vec2(x1 - 8.0, ctr.y), rx: 8.0, ry: h * 0.5), fill: lid(fill, paint), border: border, width: 1.0)
                at.x -= 4.0
            case .doubleCircle:
                c.stroke(CanvasMath.ellipse(center: ctr, rx: size.x * 0.5 - 5.0, ry: size.y * 0.5 - 5.0), closed: true, width: 1.0, color: border)
            case .crossedCircle:
                let r = size.x * 0.5 * (Float(2.0).squareRoot() * 0.5)
                line([Vec2(ctr.x - r, ctr.y - r), Vec2(ctr.x + r, ctr.y + r)])
                line([Vec2(ctr.x - r, ctr.y + r), Vec2(ctr.x + r, ctr.y - r)])
            case .dividedRect:
                line([Vec2(x0, y0 + 10.0), Vec2(x1, y0 + 10.0)])
                at.y += 5.0
            case .linedRect:
                line([Vec2(x0 + 8.0, y0), Vec2(x0 + 8.0, y1)])
                at.x += 4.0
            case .windowPane:
                line([Vec2(x0 + 10.0, y0), Vec2(x0 + 10.0, y1)])
                line([Vec2(x0, y0 + 10.0), Vec2(x1, y0 + 10.0)])
                at = Vec2(at.x + 5.0, at.y + 5.0)
            case .taggedRect:
                line([Vec2(x1 - 12.0, y1), Vec2(x1, y1 - 12.0)])
            case .linedDocument:
                line([Vec2(x0 + 8.0, y0), Vec2(x0 + 8.0, y1 - 6.0)])
                at = Vec2(at.x + 4.0, at.y - 3.0)
            case .taggedDocument:
                line([Vec2(x1 - 14.0, y1 - 4.0), Vec2(x1, y1 - 16.0)])
                at.y -= 3.0
            case .document:
                at.y -= 3.0
            case .slopedRect:
                at.y += 6.0
            case .curvedTrapezoid:
                at.x -= h / 8.0
            case .delay:
                at.x -= h / 6.0
            case .card:
                at.x += 4.0
            case .triangle:
                at.y = y0 + 0.68 * h
            case .flippedTriangle:
                at.y = y0 + 0.32 * h
            default:
                break
            }
        }

        if !shape.isUnlabelled {
            c.label(label, center: at, font: paint.font, color: textColor, align: .center)
        }
    }
}
