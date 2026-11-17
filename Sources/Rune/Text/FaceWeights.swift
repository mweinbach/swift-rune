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

    /// Reads the `OS/2` table `usWeightClass` (offset `4..<6`, big-endian `UInt16`) if present.
    internal static func os2WeightClass(of font: CTFont) -> UInt16? {
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), CTFontTableOptions(rawValue: 0)) as Data?,
              data.count >= 6 else {
            return nil
        }
        let hi = UInt16(data[data.startIndex + 4])
        let lo = UInt16(data[data.startIndex + 5])
        return (hi << 8) | lo
    }

    /// Picks a descriptor inside `familyName` whose `OS/2` weight class or trait weight matches `targetWeight` cleanly.
    internal static func matchingFace(
        inFamily familyName: String,
        targetCSSWeight: Float,
        italic: Bool,
        sizePx: CGFloat
    ) -> CTFont? {
        let queryAttrs: [CFString: Any] = [kCTFontFamilyNameAttribute: familyName]
        let queryDesc = CTFontDescriptorCreateWithAttributes(queryAttrs as CFDictionary)
        guard let descs = CTFontDescriptorCreateMatchingFontDescriptors(queryDesc, nil) as? [CTFontDescriptor],
              !descs.isEmpty else {
            return nil
        }
        var bestFont: CTFont? = nil
        var bestScore = Float.infinity
        for desc in descs {
            let traits = CTFontDescriptorCopyAttribute(desc, kCTFontTraitsAttribute) as? [CFString: Any]
            let symbolicRaw = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let isItalicFace = (CTFontSymbolicTraits(rawValue: symbolicRaw).contains(.traitItalic))
            let slantPenalty: Float = (isItalicFace == italic) ? 0 : 10_000
            let candidate = CTFontCreateWithFontDescriptor(desc, sizePx, nil)
            let faceWeight: Float
            if let os2 = os2WeightClass(of: candidate) {
                faceWeight = Float(os2)
            } else if let traitWeight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue {
                // Fallback inverse approximation of CoreText weight trait (-0.8..0.62) -> (100..900).
                faceWeight = Float(400.0 + traitWeight * 500.0)
            } else {
                faceWeight = 400.0
            }
            let diff = abs(faceWeight - targetCSSWeight) + slantPenalty
            if diff < bestScore {
                bestScore = diff
                bestFont = candidate
            }
        }
        return bestFont
    }
    #endif
}
