#if canImport(CRuneGL)
import CRuneGL
import Foundation
#if os(Windows)
import CRuneWin32
#endif

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
    #if os(Windows)
    private let directSharedCopy = rune_win_shared_gl_available() != 0
    #if canImport(CRuneMedia)
    private var planeUploaders: [UInt: WindowsDecodedUploader] = [:]
    #endif
    private var attemptedWorker = false
    #endif
    #if os(Windows) || os(Linux) || os(Android)
    private var completionWorker: OpaquePointer?
    private final class Completion: Sendable {
        let at: ContinuousClock.Instant
        let frames: [(surface: NativeSurface, frameID: UInt64)]
        init(at: ContinuousClock.Instant, frames: [(surface: NativeSurface, frameID: UInt64)]) {
            self.at = at
            self.frames = frames
        }

        func finish() {
            let completed = ContinuousClock.now
            for (surface, id) in frames {
                surface.report(FrameTiming(frameId: id, submittedAt: at, completedAt: completed))
            }
        }
    }
    #endif
    private var residents: [UInt: Resident] = [:]
    private var nextToken: UInt64 = 0
    private var participants: [(surface: NativeSurface, frameID: UInt64)] = []
    #if !(os(Linux) || os(Android))
    private struct Submission {
        let fence: UnsafeMutableRawPointer
        let at: ContinuousClock.Instant
        let frames: [(surface: NativeSurface, frameID: UInt64)]
    }
    private var pending: [Submission] = []
    #endif

    init(handle: OpaquePointer, shaderSource: (String) throws -> String) throws {
        self.handle = handle
        let vert = try shaderSource("surface.vert")
        let frag = try shaderSource("surface.frag")
        try Self.check { rune_gl_configure_surfaces(handle, vert, frag, $0, $1) }
        #if os(Linux) || os(Android)
        completionWorker = rune_gl_completion_create(handle)
        guard completionWorker != nil else { throw NativeSurfaceError.importFailed("Cannot create the GL completion receiver") }
        #endif
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
        #if os(Linux) || os(Android)
        if needsCompletionPoll { _ = pollCompletions() }
        #else
        reap(wait: false)
        #endif
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
                    #if os(Windows)
                    if case .shared = shot.frame.source { continue }
                    #if canImport(CRuneMedia)
                    if case .decoded = shot.frame.source { continue }
                    #endif
                    #endif
                    throw error
                }
            }
            kept[key] = resident
            prepared.append(Self.prepare(draw, frame: shot.frame, mirrored: shot.mirrored,
                                         srgbBlend: srgbBlend, token: resident.token))
            participants.append((surface, shot.frame.id))
        }
        #if os(Windows) && canImport(CRuneMedia)
        for key in planeUploaders.keys {
            if let frame = snapshots[key]?.frame, case .decoded = frame.source { continue }
            planeUploaders.removeValue(forKey: key)
        }
        #endif
        residents = kept
        return prepared
    }

    private func upload(_ frame: NativeSurfaceVideoFrame, key: UInt, token: UInt64) throws {
        #if os(Windows)
        #if canImport(CRuneMedia)
        if case .decoded(let picture) = frame.source {
            if !directSharedCopy {
                if try picture.withSoftwarePlanes({ y, uv in
                    try Self.check { error, capacity in
                        rune_gl_surface_upload(handle, UInt64(key), token, Int32(picture.width), Int32(picture.height),
                                               Int32(picture.format.rawValue), y.baseAddress, y.count, uv.baseAddress, uv.count,
                                               error, capacity)
                    }
                    return true
                }) == true { return }
            }
            let uploader: WindowsDecodedUploader
            if let previous = planeUploaders[key] {
                uploader = previous
            } else {
                uploader = try WindowsDecodedUploader()
                planeUploaders[key] = uploader
            }
            var source = RuneWinPlaneCopy(uploader: uploader.handle, texture: picture.texture,
                                           width: picture.width, height: picture.height, interop: directSharedCopy ? 1 : 0,
                                           transferred_on_gpu: 0)
            try Self.check { error, capacity in
                rune_gl_surface_copy_nv12(handle, UInt64(key), token, Int32(picture.width), Int32(picture.height),
                                          Int32(picture.format.rawValue), rune_win_plane_copy_gl, &source, error, capacity)
            }
            return
        }
        #endif
        if case .shared(let shared) = frame.source {
            try shared.withSnapshot(gpuCopy: directSharedCopy) { snapshot in
                let source = UnsafeMutableRawPointer(snapshot)
                if directSharedCopy,
                   rune_gl_surface_copy_rgba(handle, UInt64(key), token, Int32(frame.size.0), Int32(frame.size.1),
                                             rune_win_shared_copy_gl, source, nil, 0) != 0 { return }
                try Self.check { error, capacity in
                    rune_gl_surface_copy_rgba(handle, UInt64(key), token, Int32(frame.size.0), Int32(frame.size.1),
                                              rune_win_shared_upload_gl, source, error, capacity)
                }
            }
            return
        }
        #endif
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
        #if os(Windows)
        if !attemptedWorker {
            attemptedWorker = true
            completionWorker = rune_win_gl_completion_create()
        }
        if let worker = completionWorker, let fence = rune_gl_submit_fence(handle) {
            let retained = Unmanaged.passRetained(Completion(at: at, frames: frames))
            let queued = rune_win_gl_completion_submit(worker, fence, retained.toOpaque()) { pointer, completed in
                guard let pointer else { return }
                let submission = Unmanaged<Completion>.fromOpaque(pointer).takeRetainedValue()
                if completed != 0 { submission.finish() }
            }
            if queued != 0 { return }
            retained.release()
            pending.append(Submission(fence: fence, at: at, frames: frames))
            reap(wait: true)
            return
        }
        #elseif os(Linux) || os(Android)
        let retained = Unmanaged.passRetained(Completion(at: at, frames: frames))
        let queued = rune_gl_completion_submit(completionWorker, retained.toOpaque()) { pointer, completed in
            guard let pointer else { return }
            let submission = Unmanaged<Completion>.fromOpaque(pointer).takeRetainedValue()
            if completed != 0 { submission.finish() }
        }
        if queued == 0 {
            retained.release()
            for (surface, _) in frames { surface.setLastError("Cannot submit the GL completion fence") }
        }
        #endif
        #if !(os(Linux) || os(Android))
        guard let fence = rune_gl_surface_fence(handle) else { return }
        pending.append(Submission(fence: fence, at: at, frames: frames))
        reap(wait: frames.contains { $0.surface.isObserved } || pending.count >= 8)
        #endif
    }

    #if os(Linux) || os(Android)
    var needsCompletionPoll: Bool { rune_gl_completion_needs_poll(completionWorker) != 0 }
    func pollCompletions() -> Bool { rune_gl_completion_poll(completionWorker) != 0 }
    #endif

    func close() {
        #if os(Windows)
        rune_win_gl_completion_destroy(completionWorker, 0)
        completionWorker = nil
        #elseif os(Linux) || os(Android)
        rune_gl_completion_destroy(completionWorker, 0)
        completionWorker = nil
        #endif
        #if !(os(Linux) || os(Android))
        reap(wait: true)
        #endif
    }

    func abandon() {
        #if os(Windows)
        rune_win_gl_completion_destroy(completionWorker, 1)
        completionWorker = nil
        #elseif os(Linux) || os(Android)
        rune_gl_completion_destroy(completionWorker, 1)
        completionWorker = nil
        #endif
        #if !(os(Linux) || os(Android))
        pending.removeAll()
        #endif
    }

    #if !(os(Linux) || os(Android))
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
    #endif
}
#endif
