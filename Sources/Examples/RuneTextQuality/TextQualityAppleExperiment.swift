#if canImport(CoreGraphics) && canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation
import Rune

extension ShapedText {
    /// The text_quality experiment starts over from positioned glyphs, including
    /// fallback runs and variation instances. Its origin and output are device pixels.
    func qualityAppleExperiment(origin: SIMD2<Float>, scale: Float, hint: Bool, embolden: Float) -> [TextQualityMask] {
        guard scale.isFinite, scale > 0, origin.x.isFinite, origin.y.isFinite, embolden.isFinite else { return [] }
        var result: [TextQualityMask] = []
        qualityAppleRuns(origin: origin, scale: scale) { run, left, baseline in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard attributes[kCTRunDelegateAttributeName] == nil,
                  attributes["RunePillMarker"] == nil,
                  let rawFont = attributes[kCTFontAttributeName] else { return }
            let font = rawFont as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)
            let scaler = TextQualityAppleScaler(font: font, hint: hint)
            for (glyph, position) in zip(glyphs, positions) {
                let x = ((left + Float(position.x)) * 4).rounded() / 4
                let y = (baseline - Float(position.y)).rounded()
                // Swash's offset both selects the quarter-pixel phase and
                // recenters the (+strength, +strength) contour expansion.
                let offset = SIMD2(x.truncatingRemainder(dividingBy: 1) - embolden, -embolden)
                guard let mask = scaler.mask(glyph: glyph, offset: offset, embolden: embolden),
                      mask.width > 0, mask.height > 0,
                      let destX = Int(exactly: x.rounded(.down) + Float(mask.x)),
                      let destY = Int(exactly: y + Float(mask.y)) else { continue }
                result.append(TextQualityMask(x: destX, y: destY, width: mask.width, height: mask.height, bytes: mask.bytes))
            }
        }
        return result
    }
}

/// Independent of the production glyph atlas. The public CoreText path supplies
/// the glyph's selected variation instance. With hinting enabled Apple's
/// vertical stem transform replaces Swash's font-instruction interpreter.
private struct TextQualityAppleScaler {
    typealias Point = SIMD2<Float>
    private let design: CTFont
    private let factor: Float
    private let trueType: Bool
    private let hasOutlines: Bool
    private let hint: MacOSHintTransform?

    init(font: CTFont, hint: Bool) {
        let ppem = CTFontGetSize(font)
        let upem = CGFloat(CTFontGetUnitsPerEm(font))
        design = CTFontCreateCopyWithAttributes(font, upem, nil, nil)
        factor = upem > 0 ? Float(ppem / upem) : 0
        let tags = CTFontCopyAvailableTables(design, []).map { tables in
            Set((0..<CFArrayGetCount(tables)).map { UInt(bitPattern: CFArrayGetValueAtIndex(tables, $0)) })
        } ?? []
        trueType = tags.contains(UInt(kCTFontTableGlyf))
        hasOutlines = trueType || tags.contains(UInt(kCTFontTableCFF)) || tags.contains(UInt(kCTFontTableCFF2))
        self.hint = hint && MacOSHinter.eligible(ppem: ppem)
            ? MacOSHinter.trueTypeMetrics(font: design).flatMap { MacOSHinter.autohint($0, ppem: ppem, d: 0) } : nil
    }

    func mask(glyph: CGGlyph, offset: Point, embolden: Float) -> TextQualityMask? {
        guard hasOutlines else { return nil }
        let commands = OutlineBuilder.commands(font: design, glyph: glyph)
        // The upstream experiment sizes even a space from the translated
        // empty box. Its zero texel can overwrite the preceding glyph in the
        // raw-coverage diagnostic, although it contributes no GPU ink.
        if commands.isEmpty {
            let lo = offset.rounded(.down), hi = offset.rounded(.up)
            guard hi.x > lo.x, hi.y > lo.y, let x = Int(exactly: lo.x), let y = Int(exactly: -hi.y) else { return nil }
            return TextQualityMask(x: x, y: y, width: 1, height: 1, bytes: [0])
        }
        var points: [Point] = []
        var ends: [Int] = []
        func collect(_ point: SIMD2<Double>) {
            var p = Point(point) * factor
            if trueType {
                p = (p * 64).rounded(.toNearestOrAwayFromZero) / 64
            }
            if let hint { p.y = Float(hint.apply(Double(p.y))) }
            points.append(p)
        }
        for command in commands {
            switch command {
            case .moveTo(let p):
                if !points.isEmpty { ends.append(points.count) }
                collect(p)
            case .lineTo(let p): collect(p)
            case .quadTo(let a, let p): collect(a); collect(p)
            case .curveTo(let a, let b, let p): collect(a); collect(b); collect(p)
            case .close: break
            }
        }
        guard !points.isEmpty else { return nil }
        ends.append(points.count)
        if embolden != 0 { Self.expand(&points, ends: ends, strength: embolden) }
        var index = 0
        var lower = Point(repeating: .infinity), upper = -lower
        let positioned = commands.map { command in
            command.qualityMap { _ in
                defer { index += 1 }
                let p = points[index] + offset
                lower = lower.replacing(with: p, where: p .< lower)
                upper = upper.replacing(with: p, where: p .> upper)
                return SIMD2<Double>(p)
            }
        }
        // Zeno allocates from the control box, including any transparent rim.
        // The raw coverage diagnostic writes that rim when glyphs overlap.
        let size = upper.rounded(.up) - lower.rounded(.down)
        guard size.x > 0, size.y > 0, max(size.x, size.y) <= Float(GlyphAtlas.atlasSize) else { return nil }
        return TextQualityMask.covering(Self.contours(positioned), bounds: (lower, upper))
    }

    // Per-control-point outline emboldening and fixed point curve subdivision
    // adapted from Swash and Zeno. Copyright (c) 2020 Chad Brokaw.
    //
    // Permission is hereby granted, free of charge, to any person obtaining a copy
    // of this software and associated documentation files (the "Software"), to deal
    // in the Software without restriction, including without limitation the rights
    // to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    // copies of the Software, and to permit persons to whom the Software is
    // furnished to do so, subject to the following conditions:
    //
    // The above copyright notice and this permission notice shall be included in all
    // copies or substantial portions of the Software.
    //
    // THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    // IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    // FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    // AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    // LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    // OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    // SOFTWARE.

    private struct Edge {
        let unit: Point
        let length: Float

        init(_ from: Point, _ to: Point) {
            let v = to - from
            length = (v.x * v.x + v.y * v.y).squareRoot()
            unit = length == 0 ? .zero : v / length
        }
    }

    private static func expand(_ points: inout [Point], ends: [Int], strength: Float) {
        var previous = points[points.count - 1]
        var area: Float = 0
        for p in points {
            area += (p.y - previous.y) * (p.x + previous.x)
            previous = p
        }
        let positive = area > 0
        var start = 0
        for end in ends {
            defer { start = end }
            guard end - start >= 2 else { continue }
            let edges = (start..<end).map { i in Edge(points[i], points[i + 1 == end ? start : i + 1]) }
            guard var incoming = edges.last(where: { $0.length > 0 }),
                  var outgoing = edges.first(where: { $0.length > 0 }) else { continue }
            var next = edges
            for i in edges.indices.reversed() {
                if edges[i].length > 0 { outgoing = edges[i] }
                next[i] = outgoing
            }
            for i in edges.indices {
                let a = incoming.unit, b = next[i].unit
                let dot = a.x * b.x + a.y * b.y
                var shift = Point.zero
                if dot > -0.9396 {
                    let denominator = 1 + dot
                    let cross = (positive ? 1 : -1) * (b.x * a.y - b.y * a.x)
                    let shortest = min(incoming.length, next[i].length)
                    let miter = strength * cross <= shortest * denominator ? strength / denominator : shortest / cross
                    shift = Point(positive ? a.y + b.y : -a.y - b.y, positive ? -a.x - b.x : a.x + b.x) * miter
                }
                points[start + i] += Point(repeating: strength) + shift
                if edges[i].length > 0 { incoming = edges[i] }
            }
        }
    }

    // Zeno raster.rs uses 24.8 fixed-point curves and rounds each subdivision
    // coordinate down. Its bitmap translation puts the control points in the
    // positive quadrant before quantization, including for negative bearings.
    static func contours(_ commands: [OutlinePathCommand]) -> [[SIMD2<Double>]] {
        typealias Point = SIMD2<Double>
        typealias Fixed = SIMD2<Int>
        var contours: [[Point]] = []
        var points: [Point] = []
        var current = Fixed.zero

        func fixed(_ p: Point) -> Fixed? {
            let x = (Float(p.x) * 256).rounded(.down)
            let y = (Float(p.y) * 256).rounded(.down)
            guard let ix = Int32(exactly: x), let iy = Int32(exactly: y) else { return nil }
            return Fixed(Int(ix), Int(iy))
        }
        func shift(_ p: Fixed, _ places: Int) -> Fixed { Fixed(p.x >> places, p.y >> places) }
        func extent(_ p: Fixed) -> Int { max(abs(p.x), abs(p.y)) }
        func append(_ p: Fixed) { points.append(Point(Double(p.x) / 256, Double(p.y) / 256)) }
        func finish() {
            if points.count > 1 { contours.append(points) }
            points = []
        }
        func quad(_ a: Fixed, _ b: Fixed, _ c: Fixed, _ depth: Int) {
            guard depth > 0 else { append(c); return }
            let ab = a &+ b, bc = b &+ c
            let mid = shift(ab &+ bc, 2)
            quad(a, shift(ab, 1), mid, depth - 1)
            quad(mid, shift(bc, 1), c, depth - 1)
        }
        func cubic(_ a: Fixed, _ b: Fixed, _ c: Fixed, _ d: Fixed) {
            let near = (a &* 2) &- (b &* 3) &+ d
            let far = a &- (c &* 3) &+ (d &* 2)
            guard max(extent(near), extent(far)) > 128 else { append(d); return }
            let ab = a &+ b, bc = b &+ c, cd = c &+ d
            let abc = ab &+ bc, bcd = bc &+ cd
            let mid = shift(abc &+ bcd, 3)
            cubic(a, shift(ab, 1), shift(abc, 2), mid)
            cubic(mid, shift(bcd, 2), shift(cd, 1), d)
        }
        for command in commands {
            switch command {
            case .moveTo(let p):
                guard let start = fixed(p) else { return [] }
                finish()
                current = start
                append(start)
            case .lineTo(let p):
                guard let end = fixed(p) else { return [] }
                append(end)
                current = end
            case .quadTo(let q, let p):
                guard let control = fixed(q), let end = fixed(p) else { return [] }
                var error = extent(current &+ end &- (control &* 2))
                var depth = 0
                while error > 64 { error >>= 2; depth += 1 }
                quad(current, control, end, depth)
                current = end
            case .curveTo(let q, let r, let p):
                guard let b = fixed(q), let c = fixed(r), let end = fixed(p) else { return [] }
                cubic(current, b, c, end)
                current = end
            case .close:
                finish()
            }
        }
        finish()
        return contours
    }
}

private extension OutlinePathCommand {
    func qualityMap(_ f: (SIMD2<Double>) -> SIMD2<Double>) -> Self {
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
