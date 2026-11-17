import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// Declared weight range for an app-registered font face, mirroring CSS `@font-face`
/// `font-weight: <low> <high>` (`crates/rune/src/text/face_weights.rs`, `#853`).
///
/// Without a declaration, CoreText CSS weight matching maps intermediate weights (such as `530`
/// on IBM Plex Mono with Text `450` and Bold `700`) toward the heavier cut. When a requested
/// weight falls inside a declared face's `range`, Rune requests the declared face weight from
/// the native shaper.
public struct FaceWeights: Sendable, Hashable, Codable {
    public var family: String
    public var weight: Float
    public var range: ClosedRange<Float>

    public init(family: String, weight: Float, range: ClosedRange<Float>) {
        self.family = family
        self.weight = weight
        self.range = range
    }

    public init(family: String, weight: Float, range: (Float, Float)) {
        let lo = min(range.0, range.1)
        let hi = max(range.0, range.1)
        self.family = family
        self.weight = weight
        self.range = lo...hi
    }
}

internal enum FaceWeightsRegistry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var declared: [FaceWeights] = []
        #if canImport(CoreText)
        var descriptorsEpoch: UInt64 = 0
        var descriptors: [String: [Face]] = [:]
        #endif
    }
    private static let storage = Storage()

    internal static func set(_ faces: [FaceWeights]) {
        storage.lock.lock()
        storage.declared = faces
        storage.lock.unlock()
    }

    internal static func snapshot() -> [FaceWeights] {
        storage.lock.lock()
        let copy = storage.declared
        storage.lock.unlock()
        return copy
    }

    internal static func declaredFace(
        in faces: [FaceWeights],
        family: String,
        requestedWeight: Float
    ) -> FaceWeights? {
        for f in faces {
            if f.family.caseInsensitiveCompare(family) == .orderedSame &&
               f.range.lowerBound <= requestedWeight &&
               requestedWeight <= f.range.upperBound {
                return f
            }
        }
        return nil
    }

    #if canImport(CoreText)
    /// Resolves the target CSS weight for `requestedWeight` within `familyName` using `declared`.
    internal static func effectiveCSSWeight(
        familyName: String,
        requestedWeight: Float,
        faces: [FaceWeights]
    ) -> Float {
        guard let matched = declaredFace(in: faces, family: familyName, requestedWeight: requestedWeight) else {
            return requestedWeight
        }
        return matched.weight
    }

    private static let weightAxis = NSNumber(value: UInt32(0x77676874)) // wght

    private struct Face {
        let descriptor: CTFontDescriptor
        let weight: Float
        let width: Int
        let italic: Bool
        let variableWeight: ClosedRange<Float>?
    }

    private static func faces(in family: String) -> [Face] {
        let epoch = FontFamiliesRegistry.settingsEpoch
        storage.lock.lock()
        if storage.descriptorsEpoch != epoch {
            storage.descriptors.removeAll(keepingCapacity: true)
            storage.descriptorsEpoch = epoch
        }
        let cached = storage.descriptors[family]
        storage.lock.unlock()
        if let cached { return cached }

        let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory = NSSet(object: kCTFontFamilyNameAttribute) as CFSet
        let descriptors = CTFontDescriptorCreateMatchingFontDescriptors(query, mandatory) as? [CTFontDescriptor] ?? []
        let result = descriptors.map { descriptor in
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?
            func word(at offset: Int) -> Int? {
                guard let os2, offset + 1 < os2.count else { return nil }
                return Int(os2[offset]) << 8 | Int(os2[offset + 1])
            }
            let traits = CTFontCopyTraits(font) as NSDictionary
            let traitWeight = (traits[kCTFontWeightTrait] as? NSNumber)?.floatValue ?? 0
            let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] ?? []
            let weightRange = axes.first { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber) == weightAxis }
                .flatMap { axis -> ClosedRange<Float>? in
                    guard let low = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.floatValue,
                          let high = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.floatValue,
                          low <= high else { return nil }
                    return low...high
                }
            return Face(descriptor: descriptor, weight: word(at: 4).map(Float.init) ?? (400 + traitWeight * 500),
                        width: word(at: 6) ?? 5, italic: CTFontGetSymbolicTraits(font).contains(.traitItalic),
                        variableWeight: weightRange)
        }
        storage.lock.lock()
        if storage.descriptorsEpoch == epoch { storage.descriptors[family] = result }
        storage.lock.unlock()
        return result
    }

    // CSS Fonts' directional search, used by fontique. Between 400 and 500,
    // first look upward through 500, then below the target, then above 500.
    private static func weightRank(_ weight: Float, for target: Float) -> (Int, Float) {
        if (400...500).contains(target) {
            if weight >= target && weight <= 500 { return (0, weight - target) }
            if weight < target { return (1, target - weight) }
            return (2, weight - 500)
        }
        let preferred = target < 400 ? weight <= target : weight >= target
        return (preferred ? 0 : 1, abs(weight - target))
    }

    /// CSS matches width and style before weight. Let CoreText synthesize a slant when none exists.
    internal static func matchingFace(
        inFamily familyName: String,
        targetCSSWeight: Float,
        italic: Bool,
        sizePx: CGFloat
    ) -> CTFont? {
        let family = faces(in: familyName)
        // For a normal-width request CSS prefers progressively narrower faces before wider ones.
        let preferredWidth = family.map(\.width).min { a, b in
            (a > 5 ? 1 : 0, abs(a - 5)) < (b > 5 ? 1 : 0, abs(b - 5))
        }
        var best: (Face, Float)?
        var bestRank = (Int.max, Float.infinity)
        for face in family where face.width == preferredWidth && face.italic == italic {
            let weight = face.variableWeight.map { min(max(targetCSSWeight, $0.lowerBound), $0.upperBound) } ?? face.weight
            let rank = weightRank(weight, for: targetCSSWeight)
            if rank < bestRank {
                bestRank = rank
                best = (face, weight)
            }
        }
        guard let (face, weight) = best else { return nil }
        var descriptor = face.descriptor
        if face.variableWeight != nil {
            descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, weightAxis, CGFloat(weight))
        }
        return CTFontCreateWithFontDescriptor(descriptor, sizePx, nil)
    }
    #endif
}
