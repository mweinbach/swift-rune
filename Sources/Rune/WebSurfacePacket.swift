import Foundation

/// Byte-backed surfaces appended after the atlases in a browser RenderFrame packet.
/// Repeated placements share one upload. Retaining the previous surface also keeps
/// its object-identity key unique while the browser still references its textures.
struct WebSurfacePacket {
    typealias Participant = (surface: NativeSurface, frameID: UInt64)

    struct Cache {
        fileprivate var residents: [UInt: (surface: NativeSurface, revision: UInt64)] = [:]
        fileprivate var participants: [Participant] = []

        mutating func takeParticipants() -> [Participant] {
            defer { participants = [] }
            return participants
        }
    }

    let bytes: Data
    let count: Int
    let next: Cache

    init(_ surfaces: [SurfaceDraw], srgbBlend: Bool, size: SIMD2<UInt32>, previous: Cache = .init()) throws {
        var data = Data()
        var count = 0
        var cache = Cache()
        typealias Snapshot = (frame: NativeSurfaceVideoFrame, mirrored: Bool, revision: UInt64)
        var snapshots: [UInt: Snapshot] = [:]
        for draw in surfaces where draw.rect.z > 0 && draw.rect.w > 0 {
            let key = draw.surface.key
            guard let snapshot = snapshots[key] ?? draw.surface.renderSnapshot() else { continue }
            snapshots[key] = snapshot
            let frame = snapshot.frame
            guard case .bytes(let image) = frame.source else {
                throw NativeSurfaceError.importFailed("WebGL requires byte-backed surface planes")
            }
            let sendPlanes = (cache.residents[key] ?? previous.residents[key])?.revision != snapshot.revision
            let firstSize = sendPlanes ? image.planes[0].count : 0
            let secondSize = sendPlanes && image.planes.count == 2 ? image.planes[1].count : 0
            guard let firstLength = UInt32(exactly: firstSize), let secondLength = UInt32(exactly: secondSize),
                  data.count <= Int.max - 248,
                  firstSize <= Int.max - data.count - 248,
                  secondSize <= Int.max - data.count - 248 - firstSize else {
                throw NativeSurfaceError.importFailed("WebGL surface packet exceeds addressable memory")
            }
            let header: [UInt32] = [
                draw.beforeInstance, UInt32(truncatingIfNeeded: key), UInt32(UInt64(key) >> 32),
                UInt32(truncatingIfNeeded: snapshot.revision), UInt32(snapshot.revision >> 32),
                image.width, image.height, image.format.rawValue, firstLength, secondLength
            ]
            header.withUnsafeBytes { data.append(contentsOf: $0) }
            let uniforms = draw.glUniforms(frame: frame, mirrored: snapshot.mirrored, srgbBlend: srgbBlend,
                                          width: Int(size.x), height: Int(size.y))
            uniforms.withUnsafeBytes { data.append(contentsOf: $0) }
            if sendPlanes {
                for plane in image.planes { data.append(plane) }
            }
            cache.residents[key] = (draw.surface, snapshot.revision)
            cache.participants.append((draw.surface, frame.id))
            count += 1
        }
        self.bytes = data
        self.count = count
        self.next = cache
    }
}

/// Keeps the exact submitted frames alive until the browser signals their GL fence.
/// Per-placement timing follows the Metal and desktop GL surface lifecycle.
final class WebSurfaceTimings {
    private var next: UInt32 = 0
    private var pending: [UInt32: (at: ContinuousClock.Instant, frames: [WebSurfacePacket.Participant])] = [:]

    func submit(_ frames: [WebSurfacePacket.Participant]) -> UInt32 {
        guard !frames.isEmpty else { return 0 }
        repeat { next &+= 1 } while next == 0 || pending[next] != nil
        let token = next
        let now = ContinuousClock.now
        pending[token] = (now, frames)
        for item in frames { item.surface.report(FrameTiming(frameId: item.frameID, submittedAt: now)) }
        return token
    }

    func complete(_ token: UInt32, success: Bool) {
        guard let submission = pending.removeValue(forKey: token), success else { return }
        let now = ContinuousClock.now
        for item in submission.frames {
            item.surface.report(FrameTiming(frameId: item.frameID, submittedAt: submission.at, completedAt: now))
        }
    }
}

#if os(WASI)
extension RuneWebReactor {
    static let surfaceTimings = WebSurfaceTimings()
}

@MainActor @_cdecl("rune_web_surface_submission")
func runeWebSurfaceSubmission() -> UInt32 {
    let frames = RuneWebReactor.surfaceCache.takeParticipants()
    return RuneWebReactor.surfaceTimings.submit(frames)
}

@MainActor @_cdecl("rune_web_surface_complete")
func runeWebSurfaceComplete(_ token: UInt32, _ success: Int32) {
    RuneWebReactor.surfaceTimings.complete(token, success: success != 0)
}
#endif
