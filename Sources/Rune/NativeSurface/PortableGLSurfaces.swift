#if canImport(CRuneGL)
import CRuneGL
import Foundation

/// Keeps the latest uploaded source planes alive separately from Rune's glyph and image atlases.
/// Multiple placements of one stream share a texture and one immutable snapshot per presentation.
internal final class PortableGLSurfaces {
    private typealias Snapshot = (frame: NativeSurfaceVideoFrame, mirrored: Bool, revision: UInt64)
    private struct Resident {
        let surface: NativeSurface // keep identity valid even when the view is rebuilt
        let revision: UInt64
        let token: UInt64
    }
    private let handle: OpaquePointer
    private var residents: [UInt: Resident] = [:]
    private var nextToken: UInt64 = 0
    private var participants: [(surface: NativeSurface, frameID: UInt64)] = []
    private struct Submission {
        let fence: UnsafeMutableRawPointer
        let at: ContinuousClock.Instant
        let frames: [(surface: NativeSurface, frameID: UInt64)]
    }
    private var pending: [Submission] = []

    init(handle: OpaquePointer, shaderSource: (String) throws -> String) throws {
        self.handle = handle
        let vert = try shaderSource("surface.vert")
        let frag = try shaderSource("surface.frag")
        try Self.check { rune_gl_configure_surfaces(handle, vert, frag, $0, $1) }
    }

    private static func check(_ operation: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var message = [CChar](repeating: 0, count: 1024)
        let result = message.withUnsafeMutableBufferPointer { operation($0.baseAddress!, $0.count) }
        if result == 0 {
            let description = String(decoding: message.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw NativeSurfaceError.importFailed(description)
        }
    }

    func prepare(_ draws: [SurfaceDraw], srgbBlend: Bool) throws -> [RuneGLSurfaceDraw] {
        reap(wait: false)
        participants.removeAll(keepingCapacity: true)
        var prepared: [RuneGLSurfaceDraw] = []
        var kept: [UInt: Resident] = [:]
        var snapshots: [UInt: Snapshot] = [:]
        prepared.reserveCapacity(draws.count)
        for draw in draws where draw.rect.z > 0 && draw.rect.w > 0 {
            let surface = draw.surface
            let key = surface.key
            guard let shot = snapshots[key] ?? surface.renderSnapshot() else { continue }
            snapshots[key] = shot
            let resident: Resident
            if let existing = kept[key] ?? residents[key], existing.revision == shot.revision {
                resident = existing
            } else {
                nextToken &+= 1
                resident = Resident(surface: surface, revision: shot.revision, token: nextToken)
                do {
                    try upload(shot.frame, key: key, token: nextToken)
                    surface.setLastError(nil)
                } catch {
                    surface.setLastError(String(describing: error))
                    throw error
                }
            }
            kept[key] = resident
            prepared.append(Self.prepare(draw, frame: shot.frame, mirrored: shot.mirrored,
                                         srgbBlend: srgbBlend, token: resident.token))
            participants.append((surface, shot.frame.id))
        }
        residents = kept
        return prepared
    }

    private func upload(_ frame: NativeSurfaceVideoFrame, key: UInt, token: UInt64) throws {
        let planes = try frame.bytePlanes()
        let chroma = planes.count > 1 ? planes[1] : Data()
        try planes[0].withUnsafeBytes { (first: UnsafeRawBufferPointer) in
            try chroma.withUnsafeBytes { (second: UnsafeRawBufferPointer) in
                try Self.check { error, capacity in
                    rune_gl_surface_upload(handle, UInt64(key), token, Int32(frame.size.0), Int32(frame.size.1),
                                           Int32(frame.format.rawValue), first.bindMemory(to: UInt8.self).baseAddress, first.count,
                                           second.bindMemory(to: UInt8.self).baseAddress, second.count, error, capacity)
                }
            }
        }
    }

    private static func prepare(_ draw: SurfaceDraw, frame: NativeSurfaceVideoFrame, mirrored: Bool,
                                srgbBlend: Bool, token: UInt64) -> RuneGLSurfaceDraw {
        // Desktop GL obtains the active layer dimensions at the actual draw call.
        let groups = draw.glUniforms(frame: frame, mirrored: mirrored, srgbBlend: srgbBlend, width: 0, height: 0)
        var result = RuneGLSurfaceDraw()
        result.key = UInt64(draw.surface.key)
        result.version = token
        result.before_instance = draw.beforeInstance
        withUnsafeMutableBytes(of: &result.uniforms) { dst in groups.withUnsafeBytes { dst.copyMemory(from: $0) } }
        return result
    }

    /// Most frames simply enqueue a fence. An explicit timing observer needs its
    /// completion callback even if this is the last frame before the host sleeps.
    func didSubmit() {
        guard !participants.isEmpty else { return }
        let at = ContinuousClock.now
        let frames = participants
        participants.removeAll(keepingCapacity: true)
        for (surface, id) in frames { surface.report(FrameTiming(frameId: id, submittedAt: at)) }
        guard let fence = rune_gl_surface_fence(handle) else { return }
        pending.append(Submission(fence: fence, at: at, frames: frames))
        reap(wait: frames.contains { $0.surface.isObserved } || pending.count >= 8)
    }

    func close() { reap(wait: true) }

    private func reap(wait: Bool) {
        while let first = pending.first {
            let completed = rune_gl_surface_wait(handle, first.fence, wait ? 1 : 0)
            if completed == 0 { return }
            rune_gl_surface_fence_free(handle, first.fence)
            pending.removeFirst()
            guard completed > 0 else { continue } // context/device lost; no successful completion to report
            let at = ContinuousClock.now
            for (surface, id) in first.frames {
                surface.report(FrameTiming(frameId: id, submittedAt: first.at, completedAt: at))
            }
        }
    }
}
#endif
