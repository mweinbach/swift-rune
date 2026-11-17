import Foundation
import RuneRef

/// Bounds are in texels with exclusive right and bottom edges.
enum WebAtlasUpdate: Equatable, Sendable {
    case none
    case full
    case patch(SIMD4<Int>)

    /// The caller supplies the resident image only when its width, height and format match.
    /// Known bounds must describe every write since that resident revision.
    static func update(width: Int, height: Int, channels: Int, texels: [UInt8],
                       previous: [UInt8]?, changed: Bool, knownEdges: SIMD4<Int>? = nil) -> Self {
        guard let previous, previous.count == texels.count, width > 0, height > 0,
              channels == 1 || channels == 4 else { return .full }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: channels)
        let (size, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sizeOverflow, size == texels.count else { return .full }
        guard changed else { return .none }

        func upload(_ edges: SIMD4<Int>) -> Self {
            let payload = (edges.z - edges.x) * channels * (edges.w - edges.y)
            // A rectangle costs four additional UInt32s on the wire.
            return size - payload <= 16 ? .full : .patch(edges)
        }

        return previous.withUnsafeBufferPointer { old in
            texels.withUnsafeBufferPointer { new in
                guard let oldBase = old.baseAddress, let newBase = new.baseAddress,
                      oldBase != newBase else { return .none }
                if let edges = knownEdges, edges.x >= 0, edges.y >= 0,
                   edges.z <= width, edges.w <= height, edges.x < edges.z, edges.y < edges.w {
                    return upload(edges)
                }

                // Compare entire rows in libc. Only differing rows can extend the dirty edges.
                var leftByte = rowBytes, rightByte = 0, top = height, bottom = 0
                for y in 0..<height {
                    let a = oldBase + y * rowBytes
                    let b = newBase + y * rowBytes
                    guard memcmp(a, b, rowBytes) != 0 else { continue }
                    top = min(top, y)
                    bottom = y + 1
                    var left = 0
                    while left < leftByte && a[left] == b[left] { left += 1 }
                    leftByte = left
                    var right = rowBytes
                    while right > rightByte && a[right - 1] == b[right - 1] { right -= 1 }
                    rightByte = right
                }
                guard top < bottom else { return .none }
                return upload(SIMD4(leftByte / channels, top, (rightByte - 1) / channels + 1, bottom))
            }
        }
    }
}

/// Both atlas formats use the same resident-page and wire update rules.
protocol WebAtlasPixels {
    static var webChannels: Int { get }
    var width: Int { get }
    var height: Int { get }
    var texels: [UInt8] { get }
}

extension R8Atlas: WebAtlasPixels { static var webChannels: Int { 1 } }
extension RGBA8Atlas: WebAtlasPixels { static var webChannels: Int { 4 } }

extension RenderFrame {
    /// RSG3 always carries image descriptors, even if only the glyph atlas has overflowed.
    var webImagePages: [RGBA8Atlas] { imagePages.isEmpty ? [images] : imagePages }
    var webImageRevisions: [UInt64] { imagePages.isEmpty ? [imageRevision] : imagePageRevisions }
}

extension WebAtlasUpdate {
    static func imagePages(_ frame: RenderFrame, previous: [RGBA8Atlas], revisions: [UInt64], force: Bool) -> [Self] {
        updates(frame.webImagePages, revisions: frame.webImageRevisions,
                patches: frame.imagePages.isEmpty ? [frame.imagePatch] : frame.imagePagePatches,
                previous: previous, previousRevisions: revisions, force: force)
    }

    static func glyphPages(_ pages: [R8Atlas], frame: RenderFrame, previous: [R8Atlas],
                           revisions: [UInt64], force: Bool) -> [Self] {
        updates(pages, revisions: frame.glyphPageRevisions, patches: frame.glyphPagePatches,
                previous: previous, previousRevisions: revisions, force: force)
    }

    /// Preserve page slots and compare only changed backing stores. Empty slots retire a texture.
    private static func updates<Page: WebAtlasPixels>(
        _ pages: [Page], revisions: [UInt64], patches: [ImageAtlasPatch?],
        previous: [Page], previousRevisions: [UInt64], force: Bool
    ) -> [Self] {
        pages.enumerated().map { index, page in
            guard !page.texels.isEmpty else { return .none }
            guard !force, index < previous.count, previous[index].width == page.width,
                  previous[index].height == page.height else { return .full }
            let oldRevision = index < previousRevisions.count ? previousRevisions[index] : nil
            if let oldRevision, index < revisions.count, revisions[index] == oldRevision { return .none }
            let patch = index < patches.count ? patches[index] : nil
            return .update(width: page.width, height: page.height, channels: Page.webChannels,
                           texels: page.texels, previous: previous[index].texels, changed: true,
                           knownEdges: patch?.fromRevision == oldRevision ? patch?.edges : nil)
        }
    }

    static func slotsChanged<Page: WebAtlasPixels>(_ pages: [Page], since old: [Page]) -> Bool {
        pages.count != old.count || zip(pages, old).contains { $0.texels.isEmpty != $1.texels.isEmpty }
    }
}

/// Atlas changes for one draw. A failed packet reservation leaves the resident sequence intact.
struct WebAtlasTransfer {
    var glyph: WebAtlasUpdate
    var image: WebAtlasUpdate
    var images: [WebAtlasUpdate]?
    var glyphs: (pages: [R8Atlas], updates: [WebAtlasUpdate])?
    var sequence: SIMD2<UInt32>?
}

struct WebAtlasHistory {
    private var sizes: SIMD4<Int>?
    private var glyphRevision: UInt64?
    private var imageRevision: UInt64?
    private var sequence: UInt32?
    private var glyphTexels: [UInt8]?
    private var imageTexels: [UInt8]?
    private var glyphPages: [R8Atlas] = []
    private var imagePages: [RGBA8Atlas] = []
    private var glyphRevisions: [UInt64] = []
    private var imageRevisions: [UInt64] = []

    private func atlasSizes(_ frame: RenderFrame) -> SIMD4<Int> {
        SIMD4(frame.baseGlyphAtlas.width, frame.baseGlyphAtlas.height, frame.images.width, frame.images.height)
    }

    /// Keep CPU-filled outline masks while their page revision is resident. A new runtime
    /// frame can carry a fresh deferred-fill plan for glyphs the browser already has.
    private func resolvedGlyphPages(_ frame: RenderFrame) -> [R8Atlas] {
        let pages = frame.baseGlyphPages
        guard !frame.glyphPageFills.isEmpty else { return pages }
        if pages.count == glyphPages.count && pages.count == glyphRevisions.count &&
            frame.glyphPageRevisions == glyphRevisions {
            return glyphPages
        }
        return pages.enumerated().map { index, page in
            if index < glyphPages.count, index < glyphRevisions.count,
               index < frame.glyphPageRevisions.count, glyphRevisions[index] == frame.glyphPageRevisions[index] {
                return glyphPages[index]
            }
            guard index < frame.glyphPageFills.count else { return page }
            return frame.glyphPageFills[index]?.cpuAtlas() ?? page
        }
    }

    func prepare(_ frame: RenderFrame, force: Bool, patches: Bool) -> WebAtlasTransfer {
        let glyphPaged = !frame.baseGlyphPages.isEmpty
        let paged = glyphPaged || !frame.imagePages.isEmpty
        let hadPages = !imagePages.isEmpty, hadGlyphPages = !glyphPages.isEmpty
        let full = force || paged != hadPages || glyphPaged != hadGlyphPages || ((patches || paged) && sequence == nil)
        let sizesNow = atlasSizes(frame)
        let fullGlyph = full || sizesNow.x != sizes?.x || sizesNow.y != sizes?.y
        let fullImage = full || sizesNow.z != sizes?.z || sizesNow.w != sizes?.w
        let changedGlyphs = frame.glyphGeneration != glyphRevision
        let changedImages = frame.imageRevision != imageRevision
        var transfer = WebAtlasTransfer(glyph: fullGlyph || changedGlyphs ? .full : .none,
                                        image: fullImage || changedImages ? .full : .none)
        guard patches || paged else { return transfer }
        var slotsChanged = false
        if glyphPaged {
            // A deferred mask page can require materialization. Share the same pages with the encoder.
            let pages = resolvedGlyphPages(frame)
            let updates = WebAtlasUpdate.glyphPages(pages, frame: frame, previous: glyphPages, revisions: glyphRevisions, force: full)
            transfer.glyphs = (pages, updates)
            transfer.glyph = .none
            slotsChanged = WebAtlasUpdate.slotsChanged(pages, since: glyphPages)
        } else if !fullGlyph && changedGlyphs {
            transfer.glyph = .update(width: sizesNow.x, height: sizesNow.y, channels: 1, texels: frame.glyphs.texels,
                                     previous: glyphTexels, changed: true)
        }
        if paged {
            transfer.images = WebAtlasUpdate.imagePages(frame, previous: imagePages, revisions: imageRevisions, force: full)
            transfer.image = .none
            slotsChanged = slotsChanged || WebAtlasUpdate.slotsChanged(frame.webImagePages, since: imagePages)
        } else if !fullImage && changedImages {
            let edges = frame.imagePatch?.fromRevision == imageRevision ? frame.imagePatch?.edges : nil
            transfer.image = .update(width: sizesNow.z, height: sizesNow.w, channels: 4, texels: frame.images.texels,
                                     previous: imageTexels, changed: true, knownEdges: edges)
        }
        let changed = slotsChanged || transfer.glyph != .none || transfer.image != .none
            || transfer.glyphs?.updates.contains { $0 != .none } == true || transfer.images?.contains { $0 != .none } == true
        let base = sequence ?? 0
        transfer.sequence = SIMD2(base, changed ? base &+ 1 : base)
        return transfer
    }

    mutating func record(_ frame: RenderFrame, _ transfer: WebAtlasTransfer) {
        sizes = atlasSizes(frame)
        sequence = transfer.sequence?.y
        if transfer.sequence != nil {
            if transfer.glyphs != nil { glyphTexels = nil }
            else if transfer.glyph != .none || glyphTexels == nil { glyphTexels = frame.glyphs.texels }
            imageTexels = transfer.images == nil ? frame.images.texels : nil
            imagePages = transfer.images == nil ? [] : frame.webImagePages
            imageRevisions = transfer.images == nil ? [] : frame.webImageRevisions
            glyphPages = transfer.glyphs?.pages ?? []
            glyphRevisions = transfer.glyphs == nil ? [] : frame.glyphPageRevisions
        } else {
            glyphTexels = nil
            imageTexels = nil
            imagePages = []
            imageRevisions = []
            glyphPages = []
            glyphRevisions = []
        }
        glyphRevision = frame.glyphGeneration
        imageRevision = frame.imageRevision
    }
}
