import Foundation
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
#endif

/// Unscaled font-unit metrics used by CoreGraphics' small-size y autohinter (`crates/rune/src/text/macos/hint.rs`).
public struct MacOSHintMetrics: Equatable, Sendable {
    public var upem: Double
    public var xHeight: Double
    public var capHeight: Double
    public var maxY: Double
    public var stemHeight: Double

    public init(upem: Double, xHeight: Double, capHeight: Double, maxY: Double, stemHeight: Double) {
        self.upem = upem
        self.xHeight = xHeight
        self.capHeight = capHeight
        self.maxY = maxY
        self.stemHeight = stemHeight
    }
}

/// Piecewise-linear vertical hinting transform `[-d, a, b, B, c, C, e, E, l, m, u]` (`macos/hint.rs`).
public struct MacOSHintTransform: Equatable, Sendable {
    public var values: [Double]

    public init(values: [Double]) {
        precondition(values.count == 11)
        self.values = values
    }

    public func apply(_ y: Double) -> Double {
        let v = values
        if y < v[1] {
            return y
        } else if y <= v[2] {
            return (y - v[1]) * v[8] + v[1]
        } else if y <= v[4] {
            return (y - v[2]) * v[9] + v[3]
        } else if y <= v[6] {
            return y + (v[5] - v[4])
        } else {
            return (y - v[6]) * v[10] + v[7]
        }
    }
}

/// CoreGraphics' small-size TrueType y autohinter & `post`-table glyph lookup (`crates/rune/src/text/macos/hint.rs`).
public enum MacOSHinter {
    /// Standard Macintosh glyph name indices for `'o'` (82) and `'X'` (59).
    public static let standardGlyphO: (standard: UInt16, name: String) = (82, "o")
    public static let standardGlyphX: (standard: UInt16, name: String) = (59, "X")

    /// Integer ppem 7 through 18.
    public static func eligible(ppem: Double) -> Bool {
        ppem >= 7.0 && ppem <= 18.0 && ppem.rounded(.towardZero) == ppem
    }

    private static func eval(
        _ m: MacOSHintMetrics,
        scale: Double,
        d: Double,
        xTarget: Double,
        capTarget: Double
    ) -> MacOSHintTransform {
        let baseStem = (m.stemHeight == 0.0 ? m.capHeight : m.stemHeight)
        let stem = min(baseStem, min(m.xHeight * 0.333, (m.capHeight - m.xHeight) * 0.5)) * scale
        let lo = stem + d
        let x = m.xHeight * scale + d
        let xt = xTarget - d
        let cap = m.capHeight * scale + d
        var ct = capTarget - d
        let middle = m.capHeight * scale - stem - d
        var mt = (-2.0) * d + (ct - stem)
        let top = m.maxY * scale + d
        @inline(__always) func slope(_ a: Double, _ b: Double) -> Double {
            b == 0.0 ? 0.0 : a / b
        }
        let s1 = slope(xt - lo, x - lo)
        var s2 = slope(mt - xt, middle - x)
        var s3 = slope(top - ct, top - cap)
        if s2 < 0.75 || s2 - s1 > 0.3 {
            ct = cap
            mt = (-2.0) * d + (cap - stem)
            s2 = slope(mt - xt, middle - x)
            s3 = 1.0
        }
        return MacOSHintTransform(values: [-d, lo, x, xt, middle, mt, cap, ct, s1, s2, s3])
    }

    /// Transform for dilation radius `d` at `ppem`, or `nil` when size or metrics do not take it.
    public static func autohint(_ m: MacOSHintMetrics, ppem: Double, d: Double) -> MacOSHintTransform? {
        guard eligible(ppem: ppem), m.xHeight != m.capHeight else {
            return nil
        }
        let scale = ppem / m.upem
        let reference = min(ppem * 0.015125, 0.3)
        @inline(__always) func roundHalfUpTrunc(_ v: Double) -> Double {
            (v + 0.5).rounded(.towardZero)
        }
        var xt = roundHalfUpTrunc(m.xHeight * scale + 2.0 * reference)
        var ct = roundHalfUpTrunc(m.capHeight * scale + 2.0 * reference)
        let plainX = roundHalfUpTrunc(m.xHeight * scale)
        let plainCap = roundHalfUpTrunc(m.capHeight * scale)
        if plainX != xt {
            func cost(_ x: Double, _ c: Double) -> Double {
                [reference, 0.0].reduce(0.0) { acc, radius in
                    let t = eval(m, scale: scale, d: radius, xTarget: x, capTarget: c)
                    return acc + abs(t.values[8] - 1.0) + abs(t.values[9] - 1.0)
                }
            }
            if cost(xt, ct) > cost(plainX, plainCap) {
                xt = plainX
                ct = plainCap
            }
        }
        let t = eval(m, scale: scale, d: d, xTarget: xt, capTarget: ct)
        if m.xHeight / m.capHeight > 0.85 && t.values[9] < 0.33 {
            return nil
        }
        return t
    }

    /// Resolves the glyph ID named `name` (or standard Macintosh index `standard`) inside raw `post` table bytes.
    /// Format 1 keeps standard ordering, Format 2 maps glyph indices to standard names or custom Pascal strings,
    /// and Format 3 (used by many subsets and PingFang) names no glyphs and returns `nil`.
    public static func postGlyph(inPostTable post: Data, standard: UInt16, name: String) -> UInt16? {
        guard post.count >= 4 else { return nil }
        let b0 = post[post.startIndex]
        let b1 = post[post.startIndex + 1]
        let b2 = post[post.startIndex + 2]
        let b3 = post[post.startIndex + 3]

        @inline(__always) func readUInt16(at offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= post.count else { return nil }
            let hi = UInt16(post[post.startIndex + offset])
            let lo = UInt16(post[post.startIndex + offset + 1])
            return (hi << 8) | lo
        }

        if b0 == 0 && b1 == 1 && b2 == 0 && b3 == 0 {
            return standard
        }
        guard b0 == 0 && b1 == 2 && b2 == 0 && b3 == 0 else {
            return nil
        }
        guard let countU16 = readUInt16(at: 32) else { return nil }
        let count = Int(countU16)
        guard 34 + 2 * count <= post.count else { return nil }
        var indices: [UInt16] = []
        indices.reserveCapacity(count)
        for g in 0..<count {
            guard let idx = readUInt16(at: 34 + 2 * g) else { return nil }
            indices.append(idx)
        }
        if let g = indices.firstIndex(of: standard) {
            return UInt16(g)
        }
        let targetBytes = Array(name.utf8)
        var at = 34 + 2 * count
        var ownNames: [[UInt8]] = []
        while at < post.count {
            let len = Int(post[post.startIndex + at])
            guard at + 1 + len <= post.count else { return nil }
            let slice = Array(post[(post.startIndex + at + 1)..<(post.startIndex + at + 1 + len)])
            ownNames.append(slice)
            at += 1 + len
        }
        guard let k = ownNames.firstIndex(of: targetBytes) else { return nil }
        guard let g = indices.firstIndex(where: { Int($0) == 258 + k }) else { return nil }
        return UInt16(g)
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    /// Looks up `'o'` / `'X'` glyph ID from `font`'s OpenType `post` table (never via `cmap`), matching `#895`.
    public static func postGlyph(font: CTFont, standard: UInt16, name: String) -> CGGlyph? {
        guard let postData = CTFontCopyTable(font, CTFontTableTag(kCTFontTablePost), CTFontTableOptions(rawValue: 0)) as Data? else {
            return nil
        }
        return postGlyph(inPostTable: postData, standard: standard, name: name)
    }

    /// Stem height reported by CoreGraphics font descriptors for `.SFNS*` and `Helvetica` (`macos/hint.rs:160`).
    public static func descriptorStemHeight(font: CTFont) -> Double {
        let psName = CTFontCopyPostScriptName(font) as String
        if psName.hasPrefix(".SFNS") { return 79.0 }
        if psName == "Helvetica" { return 85.0 }
        return 0.0
    }

    /// TrueType (`glyf`) metrics for `font` resolved strictly by `'o'` and `'X'` `post` names (`macos/hint.rs:110`).
    public static func trueTypeMetrics(font: CTFont) -> MacOSHintMetrics? {
        let opts = CTFontTableOptions(rawValue: 0)
        guard CTFontCopyTable(font, CTFontTableTag(kCTFontTableGlyf), opts) != nil,
              let headData = CTFontCopyTable(font, CTFontTableTag(kCTFontTableHead), opts) as Data?,
              headData.count >= 44 else {
            return nil
        }
        let upem = Double(CTFontGetUnitsPerEm(font))
        guard upem > 0 else { return nil }
        let maxYRaw = (UInt16(headData[headData.startIndex + 42]) << 8) | UInt16(headData[headData.startIndex + 43])
        let maxY = Double(Int16(bitPattern: maxYRaw))

        let scaledToUpem = CTFontCreateCopyWithAttributes(font, CGFloat(upem), nil, nil)
        func glyphTop(standard: UInt16, name: String) -> Double? {
            guard let gid = postGlyph(font: font, standard: standard, name: name) else {
                return nil
            }
            var cgPath = CTFontCreatePathForGlyph(scaledToUpem, gid, nil)
            guard let path = cgPath else { return nil }
            var topY = -Double.infinity
            path.applyWithBlock { elemPtr in
                let elem = elemPtr.pointee
                let count: Int
                switch elem.type {
                case .moveToPoint, .addLineToPoint: count = 1
                case .addQuadCurveToPoint: count = 2
                case .addCurveToPoint: count = 3
                case .closeSubpath: count = 0
                @unknown default: count = 0
                }
                for i in 0..<count {
                    let y = Double(elem.points[i].y)
                    if y > topY { topY = y }
                }
            }
            _ = { cgPath = nil }()
            return topY.isFinite ? topY : nil
        }

        guard let xHeight = glyphTop(standard: standardGlyphO.standard, name: standardGlyphO.name),
              let capHeight = glyphTop(standard: standardGlyphX.standard, name: standardGlyphX.name) else {
            return nil
        }
        return MacOSHintMetrics(
            upem: upem,
            xHeight: xHeight,
            capHeight: capHeight,
            maxY: maxY,
            stemHeight: descriptorStemHeight(font: font)
        )
    }
    #endif
}
