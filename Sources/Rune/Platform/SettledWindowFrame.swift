import Foundation

/// Draw data owned by the last resting window frame. Holding the arrays is cheap until
/// the painter changes them, and never retains a drawable or an atlas texture.
struct SettledWindowFrame: Equatable {
    private let width: Int
    private let height: Int
    private let scale: Float
    private let srgbBlend: Bool
    private let clear: SIMD4<Float>
    private let glyphs: UInt64
    private let glyphPages: [UInt64]
    private let images: UInt64
    private let imagePages: [UInt64]
    private let outlineStore: UUID?
    private let outlineGeneration: UInt64?
    private let subpixelOutlines: Bool?
    private let marks: [UInt32]
    private let instances: [RenderInstance]

    init?(_ frame: RenderFrame, scale: Float) {
        guard frame.surfaces.isEmpty, frame.materials.isEmpty, frame.elidedLayers.isEmpty else { return nil }
        width = frame.width
        height = frame.height
        self.scale = scale
        srgbBlend = frame.srgbBlend
        clear = frame.clearColor
        glyphs = frame.glyphGeneration
        glyphPages = frame.glyphPageRevisions
        images = frame.imageRevision
        imagePages = frame.imagePageRevisions
        outlineStore = frame.outlines?.storeID
        outlineGeneration = frame.outlines?.generation
        subpixelOutlines = frame.outlines?.requestsLCD
        marks = frame.marks
        instances = frame.instances
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height, lhs.scale == rhs.scale,
              lhs.srgbBlend == rhs.srgbBlend, lhs.clear == rhs.clear,
              lhs.glyphs == rhs.glyphs, lhs.glyphPages == rhs.glyphPages,
              lhs.images == rhs.images, lhs.imagePages == rhs.imagePages,
              lhs.outlineStore == rhs.outlineStore, lhs.outlineGeneration == rhs.outlineGeneration,
              lhs.subpixelOutlines == rhs.subpixelOutlines, lhs.marks == rhs.marks,
              lhs.instances.count == rhs.instances.count else { return false }
        // The instance contains packed bit fields carried in Float lanes, including NaN.
        return lhs.instances.withUnsafeBytes { a in
            rhs.instances.withUnsafeBytes { b in
                a.baseAddress == b.baseAddress || a.elementsEqual(b)
            }
        }
    }
}

extension Runtime {
    /// Input, layout, live updates and a moved window all require another frame.
    var windowHasFrameWork: Bool { isStale || scrollMovedSinceLastFrame || hasPendingInput || livePending || hasPendingWindowFrame }
}
