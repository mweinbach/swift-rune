#if canImport(CRuneGL)
import CRuneGL
import Foundation
import RuneRef
#if os(Windows)
import CRuneWin32
#endif

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
    private var referenceProgramReady = false
    private let layerCache = PortableGLLayerCache()
    private var previousGlyphs: R8Atlas?
    private var previousImages: RGBA8Atlas?
    private var previousImageSRGB: Bool?

    init(resolve: @escaping RuneGLResolve, isGLES: Bool, shaderSource: ((String) throws -> String)? = nil) throws {
        let load = shaderSource ?? Self.bundledShader
        self.shaderSource = load
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
        #if os(Windows)
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
        try submit(width: scene.width, height: scene.height, clear: scene.clearColor,
                   srgbBlend: scene.srgbBlend, glyphs: scene.glyphs, images: scene.images,
                   instances: scene.primitives, surfaces: surfaces, production: false)
    }

    /// Select this device before the painter decides which cache children it can omit.
    func frame<State>(_ runtime: Runtime<State>, at time: Double) -> RenderFrame {
        if let handle { layerCache.bind(runtime.residentCacheTracker, handle: handle) }
        return runtime.renderFrame(at: time)
    }

    func setLayerCacheBudget(_ bytes: Int) {
        guard let handle else { return }
        rune_gl_layer_cache_budget(handle, UInt64(max(0, bytes)))
        layerCache.synchronize(handle)
    }

    func layerStats() -> LayerStats {
        guard let handle else { return LayerStats() }
        let s = rune_gl_layer_cache_stats(handle)
        return LayerStats(targets: Int(s.active_count), bytes: s.active_bytes, extraPasses: Int(s.passes),
                          allocations: s.target_allocations, cachedLayers: Int(s.count), cachedBytes: s.bytes,
                          hits: s.hits, misses: s.misses, evictions: s.evictions)
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
        let frame = try frame.preparedForGL()
        if !frameProgramReady {
            let vertex = try shaderSource("frame.vert")
            let fragment = try shaderSource("frame.frag")
            let fullscreen = try shaderSource("fullscreen.vert")
            let blur = try shaderSource("frame_blur.frag")
            var error = [CChar](repeating: 0, count: 2048)
            let capacity = error.count
            #if os(Windows)
            let shaderStart = rune_win_boot_clock()
            #endif
            guard rune_gl_configure_frame(handle, vertex, fragment, fullscreen, blur, &error, capacity) != 0 else {
                throw RenderError(Self.message(error))
            }
            #if os(Windows)
            _ = rune_win_boot_end("gl_frame_blur_shaders", shaderStart)
            #endif
            frameProgramReady = true
        }
        // The production painter stores a premultiplied clear. The GL pass accepts straight RGBA.
        var clear = frame.clearColor
        if clear.w > 0 {
            clear = SIMD4(clear.x / clear.w, clear.y / clear.w, clear.z / clear.w, clear.w)
        }
        defer { layerCache.synchronize(handle) }
        try submit(width: frame.width, height: frame.height, clear: clear, srgbBlend: frame.srgbBlend,
                   glyphs: frame.glyphs, images: frame.images, instances: frame.instances,
                   surfaces: frame.surfaces, production: true)
    }

    private static func patchAtlas(
        on handle: OpaquePointer, channels: Int32, width: Int32, height: Int32,
        previous: [UInt8]?, current: UnsafeBufferPointer<UInt8>, error: inout [CChar]
    ) -> Bool {
        guard let previous else { return true } // Allocated or resized in the render call.
        let capacity = error.count
        return previous.withUnsafeBufferPointer { old in
            if old.baseAddress == current.baseAddress { return true }
            return rune_gl_patch_atlas(handle, channels, width, height, old.baseAddress,
                                       current.baseAddress, &error, capacity) != 0
        }
    }

    private func submit<Instance>(width: Int, height: Int, clear: SIMD4<Float>, srgbBlend: Bool,
                                  glyphs glyphAtlas: R8Atlas, images imageAtlas: RGBA8Atlas,
                                  instances: [Instance], surfaces: [SurfaceDraw], production: Bool) throws {
        guard let handle else { throw RenderError("Rune GL renderer is closed") }
        guard let glyphWidth = Int32(exactly: glyphAtlas.width),
              let glyphHeight = Int32(exactly: glyphAtlas.height),
              let imageWidth = Int32(exactly: imageAtlas.width),
              let imageHeight = Int32(exactly: imageAtlas.height) else {
            throw RenderError("Rune atlas dimensions exceed the GL texture dimensions")
        }

        if nativeSurfaces == nil, !surfaces.isEmpty {
            nativeSurfaces = try PortableGLSurfaces(handle: handle, shaderSource: shaderSource)
        }
        let placements = try nativeSurfaces?.prepare(surfaces, srgbBlend: srgbBlend) ?? []
        let imageSRGB = production || !srgbBlend
        let oldGlyphs = previousGlyphs.flatMap {
            $0.width == glyphAtlas.width && $0.height == glyphAtlas.height ? $0.texels : nil
        }
        let oldImages = previousImages.flatMap {
            $0.width == imageAtlas.width && $0.height == imageAtlas.height && previousImageSRGB == imageSRGB
                ? $0.texels : nil
        }
        var error = [CChar](repeating: 0, count: 2048)
        let capacity = error.count
        let render = production ? rune_gl_render_frame : rune_gl_render_surfaces
        let result = instances.withUnsafeBytes { raw in
            placements.withUnsafeBufferPointer { draws in
                glyphAtlas.texels.withUnsafeBufferPointer { glyphs in
                    imageAtlas.texels.withUnsafeBufferPointer { images in
                        guard Self.patchAtlas(on: handle, channels: 1, width: glyphWidth, height: glyphHeight,
                                              previous: oldGlyphs, current: glyphs, error: &error),
                              Self.patchAtlas(on: handle, channels: 4, width: imageWidth, height: imageHeight,
                                              previous: oldImages, current: images, error: &error) else { return Int32(0) }
                        return withUnsafeBytes(of: clear) { color in
                            render(handle, Int32(width), Int32(height), color.bindMemory(to: Float.self).baseAddress,
                                   srgbBlend ? 1 : 0, raw.baseAddress, instances.count,
                                   oldGlyphs == nil ? glyphs.baseAddress : nil, glyphWidth, glyphHeight,
                                   oldImages == nil ? images.baseAddress : nil, imageWidth, imageHeight,
                                   draws.baseAddress, draws.count, &error, capacity)
                        }
                    }
                }
            }
        }
        guard result != 0 else {
            previousGlyphs = nil
            previousImages = nil
            previousImageSRGB = nil
            throw RenderError(Self.message(error))
        }
        nativeSurfaces?.didSubmit()
        previousGlyphs = glyphAtlas
        previousImages = imageAtlas
        previousImageSRGB = imageSRGB
    }

    func close() {
        if let handle {
            layerCache.unbind()
            nativeSurfaces?.close()
            nativeSurfaces = nil
            rune_gl_destroy(handle)
            self.handle = nil
        }
    }

    /// Releases host allocations when the owning context has been lost and cannot be made current.
    func abandon() {
        if let handle {
            layerCache.unbind()
            nativeSurfaces = nil
            rune_gl_abandon(handle)
            self.handle = nil
        }
    }

    deinit { close() }
}
#endif
