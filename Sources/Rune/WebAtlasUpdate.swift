import Foundation
import RuneRef

/// Bounds are in texels with exclusive right and bottom edges.
enum WebAtlasUpdate: Equatable, Sendable {
    case none
    case full
    case patch(SIMD4<Int>)

    /// A complete write receipt can be replayed against the matching resident revision.
    fileprivate static func region(_ edges: SIMD4<Int>, width: Int, height: Int, channels: Int) -> Self? {
        guard edges.x >= 0, edges.y >= 0, edges.z <= width, edges.w <= height,
              edges.x < edges.z, edges.y < edges.w else { return nil }
        let payload = (edges.z - edges.x) * (edges.w - edges.y) * channels
        // A rectangle costs four additional UInt32s on the wire.
        return width * height * channels - payload <= 16 ? .full : .patch(edges)
    }

    /// The caller supplies the resident image only when its width, height and format match.
    /// Known bounds must describe every write since that resident revision.
    static func update(width: Int, height: Int, channels: Int, texels: [UInt8],
                       previous: [UInt8]?, changed: Bool, knownEdges: SIMD4<Int>? = nil, visibleRows: Int? = nil) -> Self {
        guard let previous, previous.count == texels.count, width > 0, height > 0,
              channels == 1 || channels == 4 else { return .full }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: channels)
        let (size, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sizeOverflow, size == texels.count else { return .full }
        let rows = visibleRows ?? height
        guard (1...height).contains(rows) else { return .full }
        guard changed else { return .none }

        return previous.withUnsafeBufferPointer { old in
            texels.withUnsafeBufferPointer { new in
                guard let oldBase = old.baseAddress, let newBase = new.baseAddress,
                      oldBase != newBase else { return .none }
                if let edges = knownEdges, let update = region(edges, width: width, height: rows, channels: channels) {
                    return update
                }

                // Compare entire rows in libc. Only differing rows can extend the dirty edges.
                var leftByte = rowBytes, rightByte = 0, top = rows, bottom = 0
                for y in 0..<rows {
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
                let edges = SIMD4(leftByte / channels, top, (rightByte - 1) / channels + 1, bottom)
                return region(edges, width: width, height: rows, channels: channels) ?? .full
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
    /// The first shelf page grows from 256 rows as in Rust's renderer. UVs use absolute
    /// texels, and the published extent includes the transparent filtering gutter.
    var webGlyphHeight: Int {
        let height = baseGlyphAtlas.height
        guard let rows = baseGlyphUsedRows, baseGlyphPages.isEmpty, rows >= 0, rows < height else { return height }
        var capacity = min(256, height)
        while capacity < rows { capacity = min(capacity * 2, height) }
        return capacity
    }

    fileprivate var webRawGlyphRevision: UInt64? {
        guard baseGlyphPages.isEmpty, maskFills == nil, (glyphPageFills.first ?? nil) == nil else { return nil }
        return rawGlyphPageRevisions.first
    }

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

/// The browser owns the uploaded texture. Keep CPU texels only for comparisons without
/// runtime write receipts or to reuse an already rasterized deferred mask.
private struct WebResidentGlyphPage {
    let width: Int
    let height: Int
    let isEmpty: Bool
    let revision: UInt64?
    let snapshot: R8Atlas?

    init(_ page: R8Atlas, index: Int, frame: RenderFrame, previous: WebResidentGlyphPage?) {
        width = page.width
        height = page.height
        isEmpty = page.texels.isEmpty
        revision = index < frame.glyphPageRevisions.count ? frame.glyphPageRevisions[index] : nil
        let deferred = index < frame.glyphPageFills.count && frame.glyphPageFills[index] != nil
        let carried = !frame.glyphPageFills.isEmpty && previous?.snapshot != nil && previous?.revision == revision
        snapshot = deferred || carried || revision == nil || index >= frame.rawGlyphPageRevisions.count ? page : nil
    }

    func update(_ page: R8Atlas, revision next: UInt64?, patch: GlyphAtlasPatch?) -> WebAtlasUpdate {
        guard !isEmpty, width == page.width, height == page.height else { return .full }
        if let revision, revision == next { return .none }
        let edges = patch?.fromRevision == revision ? patch?.edges : nil
        if let snapshot {
            return .update(width: width, height: height, channels: 1, texels: page.texels,
                           previous: snapshot.texels, changed: true, knownEdges: edges)
        }
        guard let edges else { return .full }
        return WebAtlasUpdate.region(edges, width: width, height: height, channels: 1) ?? .full
    }
}

struct WebAtlasHistory {
    private var sizes: SIMD4<Int>?
    private var glyphRevision: UInt64?
    private var rawGlyphRevision: UInt64?
    private var imageRevision: UInt64?
    private var sequence: UInt32?
    private var glyphTexels: [UInt8]?
    private var imageTexels: [UInt8]?
    private var glyphPages: [WebResidentGlyphPage] = []
    private var imagePages: [RGBA8Atlas] = []
    private var imageRevisions: [UInt64] = []

    private func atlasSizes(_ frame: RenderFrame) -> SIMD4<Int> {
        SIMD4(frame.baseGlyphAtlas.width, frame.webGlyphHeight, frame.images.width, frame.images.height)
    }

    /// Keep CPU-filled outline masks while their page revision is resident. A new runtime
    /// frame can carry a fresh deferred-fill plan for glyphs the browser already has.
    private func resolvedGlyphPages(_ frame: RenderFrame) -> [R8Atlas] {
        let pages = frame.baseGlyphPages
        guard !frame.glyphPageFills.isEmpty else { return pages }
        return pages.enumerated().map { index, page in
            if index < glyphPages.count, index < frame.glyphPageRevisions.count,
               glyphPages[index].revision == frame.glyphPageRevisions[index], let saved = glyphPages[index].snapshot {
                return saved
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
        let pageRevision = frame.webRawGlyphRevision
        let changedGlyphs = frame.glyphGeneration != glyphRevision ||
            (patches && !glyphPaged && (pageRevision == nil || pageRevision != rawGlyphRevision))
        let changedImages = frame.imageRevision != imageRevision
        var transfer = WebAtlasTransfer(glyph: fullGlyph || changedGlyphs ? .full : .none,
                                        image: fullImage || changedImages ? .full : .none)
        guard patches || paged else { return transfer }
        var slotsChanged = false
        if glyphPaged {
            // A deferred mask page can require materialization. Share the same pages with the encoder.
            let pages = resolvedGlyphPages(frame)
            let updates: [WebAtlasUpdate] = pages.enumerated().map { index, page in
                guard !page.texels.isEmpty else { return .none }
                guard !full, index < glyphPages.count else { return .full }
                let revision = index < frame.glyphPageRevisions.count ? frame.glyphPageRevisions[index] : nil
                let patch = index < frame.glyphPagePatches.count ? frame.glyphPagePatches[index] : nil
                return glyphPages[index].update(page, revision: revision, patch: patch)
            }
            transfer.glyphs = (pages, updates)
            transfer.glyph = .none
            slotsChanged = pages.count != glyphPages.count || zip(pages, glyphPages).contains {
                $0.texels.isEmpty != $1.isEmpty
            }
        } else if !fullGlyph && changedGlyphs {
            if let revision = pageRevision {
                // Retaining the whole shelf forces a copy before each new glyph. Runtime
                // raw-page receipts identify every write since the resident publication.
                if let resident = rawGlyphRevision {
                    if resident == revision {
                        transfer.glyph = .none
                    } else if let patch = frame.rawGlyphPagePatches.first ?? nil, patch.fromRevision == resident {
                        transfer.glyph = WebAtlasUpdate.region(patch.edges, width: sizesNow.x, height: sizesNow.y,
                                                               channels: 1) ?? .full
                    }
                }
            } else {
                transfer.glyph = .update(width: sizesNow.x, height: frame.baseGlyphAtlas.height, channels: 1,
                                         texels: frame.glyphs.texels, previous: glyphTexels, changed: true, visibleRows: sizesNow.y)
            }
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
        rawGlyphRevision = sequence == nil ? nil : frame.webRawGlyphRevision
        if transfer.sequence != nil {
            if transfer.glyphs != nil || rawGlyphRevision != nil { glyphTexels = nil }
            else if transfer.glyph != .none || glyphTexels == nil { glyphTexels = frame.glyphs.texels }
            imageTexels = transfer.images == nil ? frame.images.texels : nil
            imagePages = transfer.images == nil ? [] : frame.webImagePages
            imageRevisions = transfer.images == nil ? [] : frame.webImageRevisions
            glyphPages = transfer.glyphs?.pages.enumerated().map { index, page in
                WebResidentGlyphPage(page, index: index, frame: frame, previous: index < glyphPages.count ? glyphPages[index] : nil)
            } ?? []
        } else {
            glyphTexels = nil
            imageTexels = nil
            imagePages = []
            imageRevisions = []
            glyphPages = []
        }
        glyphRevision = frame.glyphGeneration
        imageRevision = frame.imageRevision
    }
}
