#if canImport(CoreText) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
import Foundation

/// CoreGraphics' outline preparation as recovered in Rune's text/macos/smoothing.rs.
/// Device coordinates are y-up until the final A8 mask is written.
final class AppleClassicGlyph {
    typealias Point = SIMD2<Double>
    typealias Command = OutlinePathCommand

    final class Ink: Sendable, Hashable {
        let source: TextOutlineGroup.InkVariant
        let size: SIMD2<Float>
        let smoothing: FontSmoothing

        init(source: TextOutlineGroup.InkVariant, size: SIMD2<Float>, smoothing: FontSmoothing) {
            self.source = source
            self.size = size
            self.smoothing = smoothing
        }

        static func == (lhs: Ink, rhs: Ink) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    struct Bitmap {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let bearing: SIMD2<Float>
    }

    private struct Face {
        let design: CTFont
        let upem: Double
        let metrics: MacOSHintMetrics?
    }
    private var scaledFaces: [CTFont: Face] = [:]
    private var designFaces: [CTFont: Face] = [:]

    /// Access is serialized by the atlas outline lock.
    func mask(font: CTFont, glyph: CGGlyph, ppem: Float, phase: Float, shiftY: Float,
              pipeline: ApplePipeline, bucket: UInt8, maximumSide: Int) -> Bitmap? {
        guard ppem.isFinite, ppem > 0 else { return nil }
        let face: Face
        if let cached = scaledFaces[font] {
            face = cached
        } else {
            let upem = Double(CTFontGetUnitsPerEm(font))
            guard upem > 0 else { return nil }
            let design = CTFontCreateCopyWithAttributes(font, upem, nil, nil)
            if let cached = designFaces[design] {
                face = cached
            } else {
                face = Face(design: design, upem: upem, metrics: MacOSHinter.trueTypeMetrics(font: design))
                if designFaces.count >= 256 { designFaces.removeAll(keepingCapacity: true) }
                designFaces[design] = face
            }
            if scaledFaces.count >= 256 { scaledFaces.removeAll(keepingCapacity: true) }
            scaledFaces[font] = face
        }
        let scale = Double(ppem) / face.upem
        let design = OutlineBuilder.commands(font: face.design, glyph: glyph)
        let moved = design.map { $0.appleMap { $0 * scale + Point(Double(phase), 0) } }
        let radius = pipeline.dilate ? min(Double(Float(0.3)), Double(ppem) * (0.0058 + Double(min(4, bucket)) * 0.0025)) : 0
        let expanded = pipeline.dilate ? Self.dilate(moved, radius: radius) : moved
        let matrix = CTFontGetMatrix(font)
        let hint = pipeline.hint && matrix.b == 0 && matrix.c == 0
            ? face.metrics.flatMap { MacOSHinter.autohint($0, ppem: Double(ppem), d: radius) } : nil
        let hinted = hint.map { hint in expanded.map { $0.appleMap { Point($0.x, hint.apply($0.y)) } } } ?? expanded
        let contours = Self.flatten(hinted)
        return AppleClassicCoverage.mask(contours, shiftY: shiftY, maximumSide: maximumSide)
    }

    private static func floatPoint(_ p: Point) -> Point { Point(SIMD2<Float>(p)) }
    private static func mix(_ a: Point, _ b: Point, _ t: Double) -> Point {
        a.addingProduct(b - a, Point(repeating: t))
    }

    private struct Cubic {
        var p0, p1, p2, p3: Point
        init(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point) {
            self.p0 = p0
            self.p1 = p1
            self.p2 = p2
            self.p3 = p3
        }

        func split(_ t: Double) -> (Cubic, Cubic) {
            let a = mix(p0, p1, t), b = mix(p1, p2, t), c = mix(p2, p3, t)
            let d = mix(a, b, t), e = mix(b, c, t), f = mix(d, e, t)
            return (Cubic(p0, a, d, f), Cubic(f, e, c, p3))
        }

        func monotonic(_ axis: Int) -> [Cubic] {
            let s = p0[axis], x = p1[axis], y = p2[axis], end = p3[axis]
            let a = (end - s).addingProduct(x - y, 3)
            let b = (s + y).addingProduct(x, -2)
            let disc = ((x - y) * x).addingProduct(y, y - s).addingProduct(s - x, end)
            guard disc >= 0 else { return [self] }
            var roots: [Double] = []
            if a == 0 {
                if b != 0 { roots.append((s - x) * 0.5 / b) }
            } else if !(b == 0 && disc == 0) {
                let q = -b.addingProduct(b < 0 ? -1 : 1, sqrt(disc))
                // CoreGraphics uses the y difference for the second root on *both* axes.
                roots = [q / a, (p1.y - p0.y) / q]
            }
            var remainder = self, parts: [Cubic] = [], previous = 0.0
            for t in roots.filter({ $0 >= 1e-10 && $0 <= 0.9999999999 }).sorted() {
                guard t - previous >= 1e-12 else { continue }
                let (part, rest) = remainder.split((t - previous) / (1 - previous))
                parts.append(part)
                remainder = rest
                previous = t
            }
            parts.append(remainder)
            return parts
        }

        /// Exact signed area integral of a cubic, used only to choose contour winding.
        var area: Double {
            // Integral of cross(B, B') on [0, 1] in the Bernstein basis.
            let adjacent = cross(p0, p1) + cross(p2, p3)
            let interior = cross(p0, p2) + cross(p1, p2) + cross(p1, p3)
            return 0.6 * adjacent + 0.3 * interior + 0.1 * cross(p0, p3)
        }
    }

    private static func cross(_ a: Point, _ b: Point) -> Double { a.x * b.y - a.y * b.x }

    private static func normalize(_ path: [Command]) -> [Command] {
        var area = 0.0, prev = Point.zero, start = prev
        for c in path {
            switch c {
            case .moveTo(let p): start = p; prev = p
            case .lineTo(let p): area += cross(prev, p); prev = p
            case .quadTo(let a, let p):
                area += Cubic(prev, mix(prev, a, 2 / 3), mix(p, a, 2 / 3), p).area
                prev = p
            case .curveTo(let a, let b, let p): area += Cubic(prev, a, b, p).area; prev = p
            case .close: area += cross(prev, start); prev = start
            }
        }
        guard area < 0 else { return path }
        var reversed: [Command] = [], contour: [Command] = []
        func flush() {
            guard !contour.isEmpty else { return }
            reversed.append(.moveTo(prev))
            reversed.append(contentsOf: contour.reversed())
            reversed.append(.close)
            contour.removeAll(keepingCapacity: true)
        }
        for c in path {
            switch c {
            case .moveTo(let p): flush(); prev = p
            case .lineTo(let p): contour.append(.lineTo(prev)); prev = p
            case .quadTo(let a, let p): contour.append(.quadTo(a, prev)); prev = p
            case .curveTo(let a, let b, let p): contour.append(.curveTo(b, a, prev)); prev = p
            case .close: flush()
            }
        }
        flush()
        return reversed
    }

    private static func dilate(_ path: [Command], radius: Double) -> [Command] {
        var out: [Command] = [], cur = Point.zero, first = cur, started = false
        let d = Float(radius)
        func emit(_ to: Point, _ controls: (Point, Point)? = nil) {
            let delta = SIMD2<Float>(to - cur)
            func sign(_ v: Float) -> Float { v > 0 ? 1 : v < 0 ? -1 : 0 }
            let shift = SIMD2(sign(delta.y) * d, -sign(delta.x) * d)
            let offset = SIMD2<Float>(0, d)
            let start = Point(SIMD2<Float>(cur) + shift + offset)
            out.append(started ? .lineTo(start) : .moveTo(start))
            started = true
            func shifted(_ p: Point) -> Point { p + Point(shift) + Point(offset) }
            if let (a, b) = controls { out.append(.curveTo(shifted(a), shifted(b), shifted(to))) }
            else { out.append(.lineTo(shifted(to))) }
            cur = floatPoint(to)
        }
        func close() {
            guard started else { return }
            emit(first)
            out.append(.close)
            started = false
        }
        func cubic(_ c: Cubic) {
            for x in c.monotonic(0) {
                for y in x.monotonic(1) { emit(y.p3, (y.p1, y.p2)) }
            }
        }
        for c in normalize(path) {
            switch c {
            case .moveTo(let p): close(); cur = floatPoint(p); first = cur
            case .lineTo(let p): emit(p)
            case .quadTo(let q, let p):
                let qc = SIMD2<Float>(2 * q / 3)
                let a = Point(SIMD2<Float>(cur) / 3 + qc)
                cubic(Cubic(cur, a, p / 3 + Point(qc), p))
            case .curveTo(let a, let b, let p): cubic(Cubic(cur, a, b, p))
            case .close: close()
            }
        }
        close()
        return out
    }

    private static func flatten(_ path: [Command]) -> [[Point]] {
        var contours: [[Point]] = [], points: [Point] = [], cur = Point.zero
        func finish() {
            if points.count > 1 { contours.append(points) }
            points = []
        }
        func flat(_ d: Point, _ tolerance: Double) -> Bool { d.x * d.x <= tolerance && d.y * d.y <= tolerance }
        func quad(_ a: Point, _ b: Point, _ c: Point, _ depth: Int) {
            if depth > 22 || flat(a + c - 2 * b, 0.6400000000000001) { points.append(c); return }
            let l = mix(a, b, 0.5), r = mix(b, c, 0.5), m = mix(l, r, 0.5)
            quad(a, l, m, depth + 1)
            quad(m, r, c, depth + 1)
        }
        func cubic(_ c: Cubic, _ depth: Int) {
            let tolerance = 0.07111111111111111
            if depth > 22 || (flat(c.p0 + c.p2 - 2 * c.p1, tolerance) && flat(c.p1 + c.p3 - 2 * c.p2, tolerance)) {
                points.append(c.p3)
                return
            }
            let (l, r) = c.split(0.5)
            cubic(l, depth + 1)
            cubic(r, depth + 1)
        }
        for c in path {
            switch c {
            case .moveTo(let p): finish(); cur = floatPoint(p); points.append(cur)
            case .lineTo(let p): cur = floatPoint(p); points.append(cur)
            case .quadTo(let a, let p): quad(cur, floatPoint(a), floatPoint(p), 0); cur = floatPoint(p)
            case .curveTo(let a, let b, let p): cubic(Cubic(cur, floatPoint(a), floatPoint(b), floatPoint(p)), 0); cur = floatPoint(p)
            case .close: finish()
            }
        }
        finish()
        return contours
    }
}

private extension OutlinePathCommand {
    func appleMap(_ f: (SIMD2<Double>) -> SIMD2<Double>) -> Self {
        switch self {
        case .moveTo(let p): return .moveTo(f(p))
        case .lineTo(let p): return .lineTo(f(p))
        case .quadTo(let a, let p): return .quadTo(f(a), f(p))
        case .curveTo(let a, let b, let p): return .curveTo(f(a), f(b), f(p))
        case .close: return .close
        }
    }
}
#endif
