#if canImport(CRuneGL)
import CRuneGL
import Foundation
import RuneRef
#if os(Windows)
import CRuneWin32
#endif

private protocol GLAtlasPage {
    var width: Int { get }
    var height: Int { get }
    var texels: [UInt8] { get }
}
extension RGBA8Atlas: GLAtlasPage {}
extension R8Atlas: GLAtlasPage {}

private struct GLPageMeta {
    var width: Int
    var height: Int
    var empty: Bool
    var revision: UInt64?
}

private struct GLPage0Meta {
    var width: Int
    var height: Int
    var revision: UInt64?
    var srgb: Bool
}

/// Retains lightweight metadata for revision-tracked pages so producer atlases keep
/// unique Swift CoW ownership and edit in-place. Retains `[Page]` byte snapshots only
/// for untracked/legacy callers without revisions.
private struct GLResidentPages<Page: GLAtlasPage> {
    var pages: [Page]?
    var meta: [GLPageMeta] = []
    var srgb: Bool?
}

/// Renders Rune primitives into the bound framebuffer of a host-owned GL context.
/// Construct, draw and close on the context's thread while that context is current.
internal final class PortableGLRenderer {
    struct RenderError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    let adapter: DisplayGpuAdapter
    private let shaderSource: (String) throws -> String
    private(set) var handle: OpaquePointer?
    let resolver: RuneGLResolve
    let compositorDeviceKey = DeviceKey.next()
    var previousCompositorTime: Double?
    private var nativeSurfaces: PortableGLSurfaces?
    private var frameProgramReady = false
    private var maskPrograms: [Bool: Bool] = [:]
    private var grayscaleOutlinesReady: Bool?
    private var lcdOutlinesReady: Bool?
    private var outlineDiagnostic: String?
    private var maskFillsRefused = false
    private var filledPages: [Int: FilledPage] = [:]
    private(set) var gpuMaskFillCount = 0
    private struct FilledPage {
        let id: UUID
        let generation: UInt64
        let baseGeneration: UInt64
        let epoch: UInt64
        let width: Int
        let height: Int
        let count: Int

        init(_ plan: OutlineMaskPlan) {
            id = plan.curves.storeID
            generation = plan.curves.generation
            baseGeneration = plan.baseGeneration
            epoch = plan.epoch
            width = plan.base.width
            height = plan.base.height
            count = plan.fills.count
        }

        func prefix(of plan: OutlineMaskPlan) -> Int? {
            guard id == plan.curves.storeID, generation == plan.curves.generation, epoch == plan.epoch,
                  width == plan.base.width, height == plan.base.height,
                  count <= plan.fills.count else { return nil }
            return count
        }
    }
    private var uploadedOutline: (id: UUID, generation: UInt64, used: Int)?
    private let usesBundledShaders: Bool
    private var referenceProgramReady = false
    private var referenceBlurReady = false
    private let layerCache = PortableGLLayerCache()
    private var errorBuffer = [CChar](repeating: 0, count: 2048)
    private var previousGlyphs: R8Atlas?
    private var previousGlyphMeta: GLPage0Meta?
    private var imagePages = GLResidentPages<RGBA8Atlas>()
    private var glyphPages = GLResidentPages<R8Atlas>()
    private static let emptyImagePage = RGBA8Atlas()
    private static let emptyGlyphPage = R8Atlas()
    private static let singlePageTable = [RGBA8Atlas()]
    private var previousImages: RGBA8Atlas?
    private var previousImageMeta: GLPage0Meta?

    init(resolve: @escaping RuneGLResolve, isGLES: Bool, bundledShaderAssets: Bool = false,
         shaderSource: ((String) throws -> String)? = nil) throws {
        let load = shaderSource ?? Self.bundledShader
        self.shaderSource = load
        usesBundledShaders = shaderSource == nil || bundledShaderAssets
        self.resolver = resolve
        let fullscreen = try load("fullscreen.vert")
        let layer = try load("layer.frag")
        var error = [CChar](repeating: 0, count: 2048)
        let capacity = error.count
        #if os(Windows)
        let deviceStart = rune_win_boot_clock()
        #endif
        guard let handle = rune_gl_create_device(resolve, fullscreen, layer, &error, capacity) else {
            throw RenderError(Self.message(error))
        }
        if usesBundledShaders {
            // Compile the root clear and display transfer separately from layer effects.
            _ = rune_gl_configure_present(handle, fullscreen, "#define RUNE_ROOT_PASS 1\n" + layer, &error, capacity)
        }
        #if os(Windows)
        rune_win_shared_note_window()
        _ = rune_win_boot_end("gl_device_layer_shader", deviceStart)
        #endif
        self.handle = handle
        adapter = DisplayGpuAdapter(
            backend: isGLES ? .openGLES : .openGL,
            device: String(cString: rune_gl_renderer(handle)),
            vendor: String(cString: rune_gl_vendor(handle)),
            version: String(cString: rune_gl_version(handle))
        )
        adapter.reportIfRequested()
    }

    static func bundledShader(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "GL") else {
            throw RenderError("Missing bundled Rune GL shader \(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let validInstanceLayout: Bool = {
        let slots: [PartialKeyPath<Primitive>] = [
            \.rect, \.radii, \.fill, \.border, \.params, \.uv, \.clip, \.fade, \.fadeOrigin
        ]
        return MemoryLayout<Primitive>.stride == 144
            && MemoryLayout<Primitive>.offset(of: \.turn) == 136
            && slots.enumerated().allSatisfy { MemoryLayout<Primitive>.offset(of: $1) == $0 * 16 }
    }()

    private static func message(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func draw(_ scene: RefScene, surfaces: [SurfaceDraw] = []) throws {
        guard let handle else { throw RenderError("Rune GL renderer is closed") }
        try scene.validate()
        if !referenceProgramReady {
            guard Self.validInstanceLayout else {
                throw RenderError("Rune Primitive is incompatible with the GL instance buffer layout")
            }
            let vertex = try shaderSource("rune.vert")
            let fragment = try shaderSource("rune.frag")
            var error = [CChar](repeating: 0, count: 2048)
            let capacity = error.count
            guard rune_gl_configure_reference(handle, vertex, fragment, &error, capacity) != 0 else {
                throw RenderError(Self.message(error))
            }
            referenceProgramReady = true
        }
        if !frameProgramReady && !referenceBlurReady && scene.primitives.contains(where: { $0.kind == .backdropBlur }) {
            let vertex = try shaderSource("fullscreen.vert")
            let fragment = try shaderSource("frame_blur.frag")
            var error = [CChar](repeating: 0, count: 2048)
            let capacity = error.count
            guard rune_gl_configure_reference_blur(handle, vertex, fragment, &error, capacity) != 0 else {
                throw RenderError(Self.message(error))
            }
            referenceBlurReady = true
        }
        if !filledPages.isEmpty { forgetMaskPages() }
        try Self.preparePages(scene.glyphPages, channels: 1, on: handle, cache: &glyphPages, error: &errorBuffer)
        try Self.preparePages(scene.imagePages.isEmpty ? Self.singlePageTable : scene.imagePages,
                              channels: 4, srgb: !scene.srgbBlend, on: handle, cache: &imagePages, error: &errorBuffer)
        try submit(width: scene.width, height: scene.height, clear: scene.clearColor,
                   srgbBlend: scene.srgbBlend, glyphs: scene.glyphAtlas(forPage: 0), images: scene.imageAtlas(forPage: 0),
                   instances: scene.primitives, surfaces: surfaces, production: false)
    }

    /// Select this device before the painter decides which cache children it can omit.
    func frame<State>(_ runtime: Runtime<State>, at time: Double) -> RenderFrame {
        if let handle { layerCache.bind(runtime.residentCacheTracker, handle: handle) }
        let previous = runtime.textSystem.outlineRendererSupport
        runtime.textSystem.outlineRendererSupport = { [unowned self] lcd in self.prepareOutlineText(lcd: lcd) }
        let wasDeferring = runtime.textSystem.glyphAtlas.defersOutlineMasks
        runtime.textSystem.glyphAtlas.defersOutlineMasks = !maskFillsRefused
            && grayscaleOutlinesReady != false && rune_gl_outline_eligible(handle) != 0
        defer {
            runtime.textSystem.outlineRendererSupport = previous
            runtime.textSystem.glyphAtlas.defersOutlineMasks = wasDeferring
        }
        return runtime.renderFrame(at: time)
    }

    /// Negotiate the optional shader while glyphs can still choose their atlas fallback.
    func prepareOutlineText(lcd: Bool) -> (outlines: Bool, lcd: Bool) {
        guard let handle, rune_gl_outline_eligible(handle) != 0 else { return (false, false) }
        func prepare(_ dual: Bool) -> Bool {
            do {
                let vertex = try shaderSource("frame.vert")
                let fragment = try shaderSource("outline.frag") + "\n" + shaderSource("frame.frag")
                var error = [CChar](repeating: 0, count: 2048)
                let capacity = error.count
                if rune_gl_configure_outline(handle, vertex, fragment, dual ? 1 : 0, &error, capacity) == 0 {
                    outlineDiagnostic = Self.message(error)
                    return false
                }
                return true
            } catch {
                outlineDiagnostic = String(describing: error)
                return false
            }
        }
        if grayscaleOutlinesReady == nil { grayscaleOutlinesReady = prepare(false) }
        guard grayscaleOutlinesReady == true else { return (false, false) }
        if lcd && lcdOutlinesReady == nil { lcdOutlinesReady = prepare(true) }
        return (true, lcd && lcdOutlinesReady == true)
    }

    private func bindOutlines(_ snapshot: RenderOutlineAtlas?, on handle: OpaquePointer) throws {
        guard let snapshot else {
            rune_gl_select_outline(handle, 0, 0)
            return
        }
        let support = prepareOutlineText(lcd: snapshot.requestsLCD)
        guard support.outlines else { throw RenderError(outlineDiagnostic ?? "GPU glyph outlines unavailable") }
        try uploadOutlines(snapshot, on: handle)
        rune_gl_select_outline(handle, 1, support.lcd ? 1 : 0)
    }

    private func uploadOutlines(_ snapshot: RenderOutlineAtlas, on handle: OpaquePointer) throws {
        let width = Int(OutlineStore.width)
        let used = snapshot.usedTexels
        guard used > 0, used <= width * Int(OutlineStore.maxRows),
              snapshot.texels.count >= used, snapshot.texels.count % width == 0 else {
            throw RenderError("Invalid GPU outline snapshot")
        }
        let previous = uploadedOutline
        let priorUsed: Int
        if previous?.id == snapshot.storeID, previous?.generation == snapshot.generation,
           let count = previous?.used, count <= used { priorUsed = count } else { priorUsed = 0 }
        if used != priorUsed {
            let rows = (used + width - 1) / width
            var error = [CChar](repeating: 0, count: 512)
            let capacity = error.count
            let ok = snapshot.texels.withUnsafeBytes { bytes in
                rune_gl_upload_outline_rows(handle, Int32(rows), Int32(priorUsed / width),
                                            bytes.bindMemory(to: UInt32.self).baseAddress, &error, capacity)
            }
            guard ok != 0 else {
                uploadedOutline = nil
                throw RenderError(Self.message(error))
            }
            uploadedOutline = (snapshot.storeID, snapshot.generation, used)
        }
    }

    func setLayerCacheBudget(_ bytes: Int) {
        guard let handle else { return }
        rune_gl_layer_cache_budget(handle, UInt64(max(0, bytes)))
        layerCache.synchronize(handle)
    }

    /// Releases per-window scratch while keeping the cached textures named by the last frame.
    func giveBackForWindowRest(all: Bool) {
        guard let handle else { return }
        rune_gl_window_rest(handle, all ? 1 : 0)
        layerCache.synchronize(handle)
        if all {
            // A full rest drops secondary page textures together with their CPU snapshots.
            _ = rune_gl_atlas_page_count(handle, 1, 0, nil, 0)
            _ = rune_gl_atlas_page_count(handle, 4, 0, nil, 0)
            forgetAtlasSnapshots()
        }
    }

    func layerStats() -> LayerStats {
        guard let handle else { return LayerStats() }
        let s = rune_gl_layer_cache_stats(handle)
        return LayerStats(targets: Int(s.active_count), bytes: s.active_bytes, extraPasses: Int(s.passes),
                          allocations: s.target_allocations, cachedLayers: Int(s.count), cachedBytes: s.bytes,
                          hits: s.hits, misses: s.misses, evictions: s.evictions)
    }

    /// The host can compile the first frame's shaders on the thread preparing its GL context.
    func prepareFrameProgram() throws {
        guard !frameProgramReady else { return }
        guard let handle else { throw RenderError("Rune GL renderer is closed") }
        let vertex = try shaderSource("frame.vert")
        let fragment = try shaderSource("frame.frag")
        let fullscreen = try shaderSource("fullscreen.vert")
        let blur = try shaderSource("frame_blur.frag")
        var error = [CChar](repeating: 0, count: 2048)
        let capacity = error.count
        #if os(Windows)
        let shaderStart = rune_win_boot_clock()
        #endif
        let configured = rune_gl_configure_frame(handle, vertex, fragment, fullscreen, blur, &error, capacity)
        guard configured != 0 else { throw RenderError(Self.message(error)) }
        if configured == 2 {
            RuneStandardIO.error("Rune GPU refused the blur pipeline on \(adapter): \(Self.message(error))\n")
        }
        #if os(Windows)
        _ = rune_win_boot_end("gl_frame_blur_shaders", shaderStart)
        #endif
        rune_gl_enable_frame_damage(handle, usesBundledShaders ? 1 : 0)
        if usesBundledShaders, let common = try? shaderSource("common_frame.frag") {
            _ = rune_gl_configure_common_frame(handle, vertex, common, &error, capacity)
        }
        frameProgramReady = true
    }

    func draw(_ frame: RenderFrame) throws {
        guard let handle else { throw RenderError("Rune GL renderer is closed") }
        layerCache.bind(frame.residentTracker, handle: handle)
        for required in frame.elidedLayers {
            let layer = RuneGLCachedLayer(key: required.node, signature: required.signature)
            guard rune_gl_layer_cache_contains(handle, layer) != 0 else {
                throw RenderError("Rune layer \(required.node) was evicted. Rebuild the frame on its drawing context.")
            }
        }
        let needsImageFallback = try frame.validateForGL()
        try prepareFrameProgram()
        // The production painter stores a premultiplied clear. The GL pass accepts straight RGBA.
        var clear = frame.clearColor
        if clear.w > 0 {
            clear = SIMD4(clear.x / clear.w, clear.y / clear.w, clear.z / clear.w, clear.w)
        }
        defer { layerCache.synchronize(handle) }
        // Direct vector text does not sample pending glyph masks. Leave the resident
        // R8 textures and their revision receipts available to the next resting frame.
        let canDeferGlyphs = frame.outlines != nil || frame.maskFills != nil || !frame.glyphPageFills.isEmpty
        let samplesGlyphs = !canDeferGlyphs || frame.usesGlyphAtlasMasks
        let glyphPrep: PreparedGlyphPage0
        if samplesGlyphs {
            glyphPrep = try prepareGlyphs(frame, on: handle)
        } else if let meta = previousGlyphMeta {
            glyphPrep = PreparedGlyphPage0(atlas: Self.emptyGlyphPage, width: meta.width, height: meta.height,
                                           alreadyResidentOnGPU: true, revision: meta.revision, patch: nil)
        } else {
            glyphPrep = PreparedGlyphPage0(atlas: Self.emptyGlyphPage, width: Self.emptyGlyphPage.width,
                                           height: Self.emptyGlyphPage.height, alreadyResidentOnGPU: false,
                                           revision: nil, patch: nil)
        }
        try bindOutlines(frame.outlines, on: handle)
        let pages = frame.imagePages.isEmpty && needsImageFallback ? Self.singlePageTable : frame.imagePages
        try Self.preparePages(pages, channels: 4, revisions: frame.imagePageRevisions, patches: frame.imagePagePatches,
                              on: handle, cache: &imagePages, error: &errorBuffer)
        let first = frame.imagePages.first ?? frame.images
        let firstEmpty = first.texels.isEmpty
        try submit(width: frame.width, height: frame.height, clear: clear, srgbBlend: frame.srgbBlend,
                   glyphs: glyphPrep.atlas, glyphWidthOverride: glyphPrep.width, glyphHeightOverride: glyphPrep.height,
                   glyphAlreadyResident: glyphPrep.alreadyResidentOnGPU,
                   images: firstEmpty ? Self.emptyImagePage : first,
                   instances: frame.instances,
                   surfaces: frame.surfaces, production: true, glyphRevision: glyphPrep.revision,
                   glyphPatch: glyphPrep.patch,
                   imageRevision: firstEmpty ? nil : frame.imagePageRevisions.first,
                   imagePatch: firstEmpty ? nil : (frame.imagePagePatches.first ?? frame.imagePatch))
    }

    private struct PreparedGlyphPage0 {
        var atlas: R8Atlas
        var width: Int
        var height: Int
        var alreadyResidentOnGPU: Bool
        var revision: UInt64?
        var patch: GlyphAtlasPatch?
    }

    private func forgetMaskPages() {
        filledPages.removeAll(keepingCapacity: true)
        glyphPages = GLResidentPages()
        previousGlyphs = nil
        previousGlyphMeta = nil
    }

    /// Direct draws can use outlines while resting glyphs sample this device's filled R8 pages.
    /// A different store, page recycle or replay of an older snapshot reloads the page.
    private func prepareGlyphs(_ frame: RenderFrame, on handle: OpaquePointer) throws -> PreparedGlyphPage0 {
        let plans: [OutlineMaskPlan?] = frame.glyphPageFills.isEmpty ? frame.maskFills.map { [$0] } ?? [] : frame.glyphPageFills
        if !maskFillsRefused, plans.contains(where: { $0 != nil }), rune_gl_outline_eligible(handle) != 0 {
            do {
                if filledPages.keys.contains(where: { !plans.indices.contains($0) || plans[$0] == nil }) {
                    forgetMaskPages()
                }
                try Self.preparePages(frame.baseGlyphPages, channels: 1, revisions: frame.rawGlyphPageRevisions,
                                      patches: frame.rawGlyphPagePatches, maskFills: plans,
                                      on: handle, cache: &glyphPages, error: &errorBuffer)
                var filledPage0: OutlineMaskPlan?
                for (page, plan) in plans.enumerated() {
                    guard let plan else { continue }
                    var patch: GlyphAtlasPatch?
                    if frame.rawGlyphPageRevisions.indices.contains(page), frame.rawGlyphPageRevisions[page] == plan.baseGeneration,
                       frame.rawGlyphPagePatches.indices.contains(page) {
                        patch = frame.rawGlyphPagePatches[page]
                    }
                    try fillMasks(plan, page: page, patch: patch, on: handle)
                    if page == 0 { filledPage0 = plan }
                }
                if let plan0 = filledPage0 {
                    // Page zero has already been uploaded and GPU-filled by fillMasks above.
                    // Record only its dimensions so plan.base keeps unique CoW ownership.
                    previousGlyphs = nil
                    previousGlyphMeta = GLPage0Meta(width: plan0.base.width, height: plan0.base.height,
                                                    revision: nil, srgb: false)
                    return PreparedGlyphPage0(atlas: Self.emptyGlyphPage, width: plan0.base.width,
                                              height: plan0.base.height, alreadyResidentOnGPU: true,
                                              revision: nil, patch: nil)
                }
                let base0 = frame.baseGlyphPages.first ?? frame.baseGlyphAtlas
                let empty = base0.texels.isEmpty
                let resolved = empty ? Self.emptyGlyphPage : base0
                return PreparedGlyphPage0(atlas: resolved, width: resolved.width, height: resolved.height,
                                          alreadyResidentOnGPU: false,
                                          revision: empty ? nil : frame.rawGlyphPageRevisions.first,
                                          patch: empty ? nil : (frame.rawGlyphPagePatches.first ?? nil))
            } catch {
                maskFillsRefused = true
                forgetMaskPages()
                RuneStandardIO.error("Rune GPU glyph masks use the CPU fallback on \(adapter): \(error)\n")
            }
        }
        if !filledPages.isEmpty { forgetMaskPages() }
        let materialized = frame.glyphPages
        try Self.preparePages(materialized, channels: 1, revisions: frame.glyphPageRevisions,
                              patches: frame.glyphPagePatches, on: handle, cache: &glyphPages, error: &errorBuffer)
        let mat0 = materialized.first ?? frame.glyphs
        let empty = mat0.texels.isEmpty
        let resolved = empty ? Self.emptyGlyphPage : mat0
        return PreparedGlyphPage0(atlas: resolved, width: resolved.width, height: resolved.height,
                                  alreadyResidentOnGPU: false,
                                  revision: empty ? nil : frame.glyphPageRevisions.first,
                                  patch: empty ? nil : (frame.glyphPagePatches.first ?? nil))
    }

    private func prepareMaskProgram(unitWindfoil: Bool, on handle: OpaquePointer) -> Bool {
        if usesBundledShaders && maskPrograms[unitWindfoil] == nil {
            maskPrograms[unitWindfoil] = false
            if let vertex = try? shaderSource("frame.vert"), let curves = try? shaderSource("outline.frag"),
               let mask = try? shaderSource("outline_mask.frag") {
                var error = [CChar](repeating: 0, count: 512)
                let capacity = error.count
                let profile = unitWindfoil ? "#define RUNE_UNIT_WINFOIL 1\n" : ""
                maskPrograms[unitWindfoil] = rune_gl_configure_mask_fill(handle, vertex, profile + curves + "\n" + mask,
                                                                       unitWindfoil ? 1 : 0, &error, capacity) != 0
            }
        }
        return maskPrograms[unitWindfoil] == true || (!unitWindfoil && prepareOutlineText(lcd: false).outlines)
    }

    private func fillMasks(_ plan: OutlineMaskPlan, page: Int, patch: GlyphAtlasPatch?, on handle: OpaquePointer) throws {
        let resident = filledPages[page]
        var prefix = resident?.prefix(of: plan)
        let sameBase = resident?.baseGeneration == plan.baseGeneration
        if sameBase, prefix == plan.fills.count { return }
        var jobs: [RenderInstance] = []
        var unitWindfoil = usesBundledShaders
        func enqueue(_ item: QueuedOutlineFill) {
            if unitWindfoil { unitWindfoil = item.isUnitWindfoil(in: plan.curves) }
            jobs.append(item.instance)
        }
        var error = [CChar](repeating: 0, count: 512)
        let width = Int32(plan.base.width), height = Int32(plan.base.height)
        if !sameBase {
            if let retained = prefix, let patch, patch.fromRevision == resident?.baseGeneration {
                // An upload may replace already-filled masks inside its bounding rectangle.
                let ok = plan.base.texels.withUnsafeBufferPointer {
                    Self.patchRegion(on: handle, channels: 1, page: page, width: width, height: height,
                                     patch: patch, current: $0, error: &error)
                }
                guard ok else { throw RenderError(Self.message(error)) }
                for item in plan.fills.prefix(retained) where item.overlaps(patch.edges, in: plan.base) { enqueue(item) }
            } else {
                prefix = nil
            }
        }
        for item in plan.fills.dropFirst(prefix ?? 0) { enqueue(item) }
        if prefix == nil || !jobs.isEmpty {
            let simple = unitWindfoil && prepareMaskProgram(unitWindfoil: true, on: handle)
            guard simple || prepareMaskProgram(unitWindfoil: false, on: handle) else {
                throw RenderError("GPU glyph mask pipeline unavailable")
            }
            try uploadOutlines(plan.curves, on: handle)
            let capacity = error.count
            let ok = jobs.withUnsafeBytes { instances in
                plan.base.texels.withUnsafeBufferPointer { base in
                    rune_gl_fill_outline_masks_for_profile(handle, page, width, height, prefix == nil ? base.baseAddress : nil,
                                                           instances.baseAddress, jobs.count, simple ? 1 : 0, &error, capacity)
                }
            }
            guard ok != 0 else { throw RenderError(Self.message(error)) }
            gpuMaskFillCount += jobs.count
        }
        filledPages[page] = FilledPage(plan)
    }

    /// Retain lightweight metadata for revision-tracked frames (preserving unique CoW
    /// storage in the producer atlas) and retain immutable snapshots only for untracked callers.
    private static func preparePages<Page: GLAtlasPage>(
        _ pages: [Page], channels: Int32, revisions: [UInt64] = [], patches: [ImageAtlasPatch?] = [],
        maskFills: [OutlineMaskPlan?] = [],
        srgb: Bool = true, on handle: OpaquePointer, cache: inout GLResidentPages<Page>,
        error: inout [CChar]
    ) throws {
        let tracked = !revisions.isEmpty && revisions.count == pages.count
        if cache.srgb == srgb {
            if tracked, cache.meta.count == pages.count {
                var allMatch = true
                for index in pages.indices.dropFirst() {
                    if maskFills.indices.contains(index), maskFills[index] != nil { continue }
                    let page = pages[index]
                    let resident = cache.meta[index]
                    if resident.empty != page.texels.isEmpty || resident.width != page.width ||
                       resident.height != page.height || resident.revision != revisions[index] {
                        allMatch = false
                        break
                    }
                }
                if allMatch {
                    cache.pages = nil
                    if !pages.isEmpty {
                        cache.meta[0] = GLPageMeta(width: pages[0].width, height: pages[0].height,
                                                   empty: pages[0].texels.isEmpty, revision: revisions[0])
                    }
                    return
                }
            } else if !tracked, let previous = cache.pages, previous.count == pages.count,
                      previous.withUnsafeBufferPointer({ old in
                          pages.withUnsafeBufferPointer { old.baseAddress == $0.baseAddress }
                      }) {
                return
            }
        }
        let capacity = error.count
        error[0] = 0
        let oldPages = cache.srgb == srgb ? cache.pages : nil
        let oldMeta = cache.srgb == srgb ? cache.meta : []
        let oldCount = cache.srgb == srgb ? (oldPages?.count ?? oldMeta.count) : -1
        // A failed later page must cause a full retry, including any pages already uploaded.
        cache.pages = nil
        cache.meta.removeAll(keepingCapacity: true)
        cache.srgb = nil
        if oldCount != pages.count {
            guard rune_gl_atlas_page_count(handle, channels, pages.count, &error, capacity) != 0 else {
                throw RenderError(Self.message(error))
            }
        }
        for index in pages.indices.dropFirst() {
            if maskFills.indices.contains(index), maskFills[index] != nil { continue }
            let page = pages[index]
            let prevMeta: GLPageMeta? = oldMeta.indices.contains(index) ? oldMeta[index] : nil
            let prevPage: Page? = oldPages.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            let prevEmpty = prevMeta?.empty ?? prevPage?.texels.isEmpty ?? false
            if page.texels.isEmpty {
                if prevEmpty { continue }
                guard rune_gl_upload_atlas_page(handle, channels, index, 0, 0, srgb ? 1 : 0, nil, nil, &error, capacity) != 0 else {
                    throw RenderError(Self.message(error))
                }
                continue
            }
            let rev: UInt64? = tracked ? revisions[index] : nil
            let prevWidth = prevMeta?.width ?? prevPage?.width ?? 0
            let prevHeight = prevMeta?.height ?? prevPage?.height ?? 0
            let sameResident = (prevMeta != nil || prevPage != nil) && !prevEmpty &&
                prevWidth == page.width && prevHeight == page.height
            if sameResident, let rev, let prevRev = prevMeta?.revision, prevRev == rev {
                continue
            }
            let result = page.texels.withUnsafeBufferPointer { pixels in
                if sameResident {
                    if patches.indices.contains(index), let patch = patches[index],
                       let prevRev = prevMeta?.revision, patch.fromRevision == prevRev {
                        return Self.patchRegion(on: handle, channels: channels, page: index, width: Int32(page.width), height: Int32(page.height),
                                                patch: patch, current: pixels, error: &error)
                    }
                    if let prevPage, !prevPage.texels.isEmpty {
                        return prevPage.texels.withUnsafeBufferPointer { before in
                            if before.baseAddress == pixels.baseAddress { return true }
                            return rune_gl_upload_atlas_page(handle, channels, index, Int32(page.width), Int32(page.height), srgb ? 1 : 0,
                                                             before.baseAddress, pixels.baseAddress, &error, capacity) != 0
                        }
                    }
                }
                return rune_gl_upload_atlas_page(handle, channels, index, Int32(page.width), Int32(page.height), srgb ? 1 : 0,
                                                 nil, pixels.baseAddress, &error, capacity) != 0
            }
            guard result else { throw RenderError(Self.message(error)) }
        }
        cache.meta.reserveCapacity(pages.count)
        for index in pages.indices {
            let page = pages[index]
            let isMasked = maskFills.indices.contains(index) && maskFills[index] != nil
            cache.meta.append(GLPageMeta(width: page.width, height: page.height,
                                         empty: page.texels.isEmpty,
                                         revision: (tracked && !isMasked) ? revisions[index] : nil))
        }
        cache.pages = tracked ? nil : pages
        cache.srgb = srgb
    }

    private static func patchRegion(on handle: OpaquePointer, channels: Int32, page: Int, width: Int32, height: Int32,
                                    patch: ImageAtlasPatch, current: UnsafeBufferPointer<UInt8>, error: inout [CChar]) -> Bool {
        let rect = patch.edges
        guard rect.x >= 0, rect.y >= 0, rect.z <= Int(width), rect.w <= Int(height),
              rect.x < rect.z, rect.y < rect.w else { return false }
        let capacity = error.count
        return rune_gl_patch_atlas_region(handle, channels, page, width, height, Int32(rect.x), Int32(rect.y),
                                          Int32(rect.z), Int32(rect.w), current.baseAddress, &error, capacity) != 0
    }

    private static func patchAtlas(
        on handle: OpaquePointer, channels: Int32, width: Int32, height: Int32,
        previous: [UInt8]?, current: UnsafeBufferPointer<UInt8>, patch: ImageAtlasPatch? = nil, error: inout [CChar]
    ) -> Bool {
        if let patch {
            return patchRegion(on: handle, channels: channels, page: 0, width: width, height: height, patch: patch, current: current, error: &error)
        }
        guard let previous else { return true } // Allocated or resized in the render call, or revision-matched.
        let capacity = error.count
        return previous.withUnsafeBufferPointer { old in
            if old.baseAddress == current.baseAddress { return true }
            return rune_gl_patch_atlas(handle, channels, width, height, old.baseAddress,
                                       current.baseAddress, &error, capacity) != 0
        }
    }

    private func submit<Instance>(width: Int, height: Int, clear: SIMD4<Float>, srgbBlend: Bool,
                                  glyphs glyphAtlas: R8Atlas, glyphWidthOverride: Int? = nil,
                                  glyphHeightOverride: Int? = nil, glyphAlreadyResident: Bool = false,
                                  images imageAtlas: RGBA8Atlas,
                                  instances: [Instance], surfaces: [SurfaceDraw], production: Bool,
                                  glyphRevision: UInt64? = nil, glyphPatch: ImageAtlasPatch? = nil,
                                  imageRevision: UInt64? = nil, imagePatch: ImageAtlasPatch? = nil) throws {
        guard let handle else { throw RenderError("Rune GL renderer is closed") }
        let gWidth = glyphWidthOverride ?? glyphAtlas.width
        let gHeight = glyphHeightOverride ?? glyphAtlas.height
        guard let glyphWidth = Int32(exactly: gWidth),
              let glyphHeight = Int32(exactly: gHeight),
              let imageWidth = Int32(exactly: imageAtlas.width),
              let imageHeight = Int32(exactly: imageAtlas.height) else {
            throw RenderError("Rune atlas dimensions exceed the GL texture dimensions")
        }

        if nativeSurfaces == nil, !surfaces.isEmpty {
            nativeSurfaces = try PortableGLSurfaces(handle: handle, shaderSource: shaderSource)
        }
        let placements = try nativeSurfaces?.prepare(surfaces, srgbBlend: srgbBlend) ?? []
        let imageSRGB = production || !srgbBlend

        let glyphFullUpload: Bool
        let trustedGlyphPatch: ImageAtlasPatch?
        let oldGlyphs: [UInt8]?
        if glyphAlreadyResident {
            glyphFullUpload = false
            trustedGlyphPatch = nil
            oldGlyphs = nil
        } else if let prev = previousGlyphMeta, prev.width == gWidth, prev.height == gHeight, !prev.srgb {
            if let rev = glyphRevision, let prevRev = prev.revision, rev == prevRev {
                glyphFullUpload = false
                trustedGlyphPatch = nil
                oldGlyphs = nil
            } else if let patch = glyphPatch, let prevRev = prev.revision, patch.fromRevision == prevRev {
                glyphFullUpload = false
                trustedGlyphPatch = patch
                oldGlyphs = nil
            } else if let old = previousGlyphs, old.width == gWidth, old.height == gHeight {
                glyphFullUpload = false
                trustedGlyphPatch = nil
                oldGlyphs = old.texels
            } else {
                glyphFullUpload = true
                trustedGlyphPatch = nil
                oldGlyphs = nil
            }
        } else {
            glyphFullUpload = true
            trustedGlyphPatch = nil
            oldGlyphs = nil
        }

        let imageFullUpload: Bool
        let trustedPatch: ImageAtlasPatch?
        let oldImages: [UInt8]?
        if let prev = previousImageMeta, prev.width == imageAtlas.width, prev.height == imageAtlas.height, prev.srgb == imageSRGB {
            if let rev = imageRevision, let prevRev = prev.revision, rev == prevRev {
                imageFullUpload = false
                trustedPatch = nil
                oldImages = nil
            } else if let patch = imagePatch, let prevRev = prev.revision, patch.fromRevision == prevRev {
                imageFullUpload = false
                trustedPatch = patch
                oldImages = nil
            } else if let old = previousImages, old.width == imageAtlas.width, old.height == imageAtlas.height {
                imageFullUpload = false
                trustedPatch = nil
                oldImages = old.texels
            } else {
                imageFullUpload = true
                trustedPatch = nil
                oldImages = nil
            }
        } else {
            imageFullUpload = true
            trustedPatch = nil
            oldImages = nil
        }

        let capacity = errorBuffer.count
        errorBuffer[0] = 0
        let render = production ? rune_gl_render_frame : rune_gl_render_surfaces
        let result = instances.withUnsafeBytes { raw in
            placements.withUnsafeBufferPointer { draws in
                glyphAtlas.texels.withUnsafeBufferPointer { glyphs in
                    imageAtlas.texels.withUnsafeBufferPointer { images in
                        guard Self.patchAtlas(on: handle, channels: 1, width: glyphWidth, height: glyphHeight,
                                              previous: oldGlyphs, current: glyphs, patch: trustedGlyphPatch, error: &errorBuffer),
                              Self.patchAtlas(on: handle, channels: 4, width: imageWidth, height: imageHeight,
                                              previous: oldImages, current: images, patch: trustedPatch, error: &errorBuffer) else { return Int32(0) }
                        return withUnsafeBytes(of: clear) { color in
                            render(handle, Int32(width), Int32(height), color.bindMemory(to: Float.self).baseAddress,
                                   srgbBlend ? 1 : 0, raw.baseAddress, instances.count,
                                   glyphFullUpload ? glyphs.baseAddress : nil, glyphWidth, glyphHeight,
                                   imageFullUpload ? images.baseAddress : nil, imageWidth, imageHeight,
                                   draws.baseAddress, draws.count, &errorBuffer, capacity)
                        }
                    }
                }
            }
        }
        guard result != 0 else {
            forgetAtlasSnapshots()
            throw RenderError(Self.message(errorBuffer))
        }
        nativeSurfaces?.didSubmit()
        if !glyphAlreadyResident {
            previousGlyphMeta = GLPage0Meta(width: gWidth, height: gHeight, revision: glyphRevision, srgb: false)
            previousGlyphs = glyphRevision == nil ? glyphAtlas : nil
        }
        previousImageMeta = GLPage0Meta(width: imageAtlas.width, height: imageAtlas.height, revision: imageRevision, srgb: imageSRGB)
        previousImages = imageRevision == nil ? imageAtlas : nil
    }

    #if os(Linux) || os(Android)
    var needsSurfaceCompletionPoll: Bool { nativeSurfaces?.needsCompletionPoll == true }
    func pollSurfaceCompletions() -> Bool { nativeSurfaces?.pollCompletions() == true }
    #endif

    private func forgetAtlasSnapshots() {
        filledPages.removeAll()
        glyphPages = GLResidentPages()
        imagePages = GLResidentPages()
        previousGlyphs = nil
        previousGlyphMeta = nil
        previousImages = nil
        previousImageMeta = nil
    }

    func close() {
        if let handle {
            layerCache.unbind()
            nativeSurfaces?.close()
            nativeSurfaces = nil
            forgetAtlasSnapshots()
            rune_gl_destroy(handle)
            self.handle = nil
        }
    }

    /// Releases host allocations when the owning context has been lost and cannot be made current.
    func abandon() {
        if let handle {
            layerCache.unbind()
            nativeSurfaces?.abandon()
            nativeSurfaces = nil
            forgetAtlasSnapshots()
            rune_gl_abandon(handle)
            self.handle = nil
        }
    }

    deinit { close() }
}
#endif
