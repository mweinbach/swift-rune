#if canImport(CRuneOffscreenGL)
import CRuneGL
import CRuneOffscreenGL
import RuneRef

/// A private GL context and resizable RGBA8 target for synchronous frame capture.
/// Open, use, and close on the same thread. Close nested contexts in reverse order.
public final class OffscreenGLContext {
    private var handle: OpaquePointer?
    public static let resolve: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = rune_offscreen_gl_proc
    #if os(Linux)
    public static let isGLES = true
    #else
    public static let isGLES = false
    #endif

    public init() throws {
        var message = [CChar](repeating: 0, count: 512)
        let size = message.count
        guard let handle = rune_offscreen_gl_open(&message, size) else {
            let reason = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw OffscreenRenderError.unavailable("Cannot create offscreen GL context: \(reason)")
        }
        self.handle = handle
    }

    public func makeCurrent() throws {
        guard let handle, rune_offscreen_gl_current(handle) != 0 else {
            throw OffscreenRenderError.capture("Cannot make offscreen GL context current")
        }
    }

    @discardableResult
    func bindFramebuffer(width: Int, height: Int) throws -> OpaquePointer {
        guard width > 0, width <= 16384, height > 0, height <= 16384 else {
            throw RefSceneError.invalidDimensions(width: width, height: height)
        }
        guard let handle, rune_offscreen_gl_bind(handle, Int32(width), Int32(height)) != 0 else {
            throw OffscreenRenderError.capture("Cannot bind offscreen GL framebuffer of size \(width)x\(height)")
        }
        return handle
    }

    /// Flushes the preceding draw, timestamps submission, then waits for that GPU work to finish.
    func finishSubmission(_ renderer: OpaquePointer?) throws -> ContinuousClock.Instant {
        guard let renderer, let fence = rune_gl_submit_fence(renderer) else {
            throw OffscreenRenderError.capture("Cannot submit an offscreen GL fence")
        }
        let submitted = ContinuousClock.now
        defer { rune_gl_surface_fence_free(renderer, fence) }
        guard rune_gl_surface_wait(renderer, fence, 1) == 1 else {
            throw OffscreenRenderError.capture("The offscreen GL frame did not complete")
        }
        return submitted
    }

    /// Draw into the bound color attachment, then read its pixels in Rune's top-down row order.
    public func withFramebuffer(width: Int, height: Int, _ draw: () throws -> Void) throws -> Frame {
        let handle = try bindFramebuffer(width: width, height: height)
        try draw()
        let stride = width * 4
        let rgba = try [UInt8](unsafeUninitializedCapacity: stride * height) { pixels, count in
            guard rune_offscreen_gl_read(handle, pixels.baseAddress, pixels.count) != 0 else {
                throw OffscreenRenderError.capture("Cannot read the offscreen GL framebuffer")
            }
            count = pixels.count
            guard height > 1, let bytes = pixels.baseAddress else { return }
            try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: stride) { row in
                guard let rowStart = row.baseAddress else {
                    throw OffscreenRenderError.capture("Cannot allocate a row for GL framebuffer readback")
                }
                for y in 0..<(height / 2) {
                    let top = bytes.advanced(by: y * stride)
                    let bottom = bytes.advanced(by: (height - 1 - y) * stride)
                    rowStart.update(from: top, count: stride)
                    top.update(from: bottom, count: stride)
                    bottom.update(from: rowStart, count: stride)
                }
            }
        }
        return Frame(width: width, height: height, rgba: rgba)
    }

    public func close() {
        if let handle {
            rune_offscreen_gl_close(handle)
            self.handle = nil
        }
    }

    deinit { close() }
}
#endif
