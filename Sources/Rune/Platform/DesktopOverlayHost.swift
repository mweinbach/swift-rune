#if os(Windows) || os(Linux)
import Foundation
import CRuneGL

enum DesktopOverlayCommand {
    case prewarm, show(Double), hide(Double), configure, refollow, focus, wake, release
}

@MainActor
protocol DesktopOverlayHost: AnyObject {
    func apply(_ command: DesktopOverlayCommand)
    func close()
    func releaseGPUOnHide() -> Bool
}

extension DesktopOverlayHost {
    func releaseGPUOnHide() -> Bool { false }
}

/// A handle can be created before App.run and updated from any thread. Only the
/// native event loop creates, dispatches to, and tears down its platform window.
final class DesktopOverlayRegistry: @unchecked Sendable {
    static let shared = DesktopOverlayRegistry()
    private typealias Work = @MainActor () -> Void
    private let lock = NSLock()
    private var wake: (@Sendable () -> Void)?
    private var pending: [(id: UUID, work: Work)] = []
    private var pendingWakes: Set<UUID> = []
    @MainActor private var hosts: [UUID: any DesktopOverlayHost] = [:]
    @MainActor private var draining = false

    private init() {}

    @MainActor func start(wake: @escaping @Sendable () -> Void) {
        lock.withLock { self.wake = wake }
    }

    func send<State>(_ command: DesktopOverlayCommand, handle: OverlayHandle<State>, id: UUID) {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            // Headless renders never allocate a native host. Before the event loop
            // starts, only show/prewarm can create work worth retaining.
            if wake == nil && !pending.contains(where: { $0.id == id }) {
                switch command { case .show, .prewarm: break; default: return nil }
            }
            if case .wake = command, !pendingWakes.insert(id).inserted { return nil }
            pending.append((id, { [weak handle] in
                guard let handle else { return }
                switch command {
                case .release:
                    if self.hosts[id]?.releaseGPUOnHide() != true { self.hosts.removeValue(forKey: id)?.close() }
                case .show, .prewarm:
                    do {
                        if self.hosts[id] == nil {
                            #if os(Windows)
                            self.hosts[id] = try RuneWindowsOverlayHost(handle: handle)
                            #else
                            self.hosts[id] = try RuneLinuxOverlayHost(handle: handle)
                            #endif
                        }
                        self.hosts[id]?.apply(command)
                    } catch { handle.desktopFailure(String(describing: error)) }
                default: self.hosts[id]?.apply(command)
                }
            }))
            return wake
        }
        signal?()
    }

    func remove(_ id: UUID) {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            pending.removeAll { $0.id == id }
            pendingWakes.remove(id)
            guard let wake else { return nil }
            pending.append((id, { self.hosts.removeValue(forKey: id)?.close() }))
            return wake
        }
        signal?()
    }

    @MainActor func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        let work = lock.withLock {
            let work = pending
            pending.removeAll(keepingCapacity: true)
            pendingWakes.removeAll(keepingCapacity: true)
            return work
        }
        for item in work { item.work() }
    }

    @MainActor func finish() {
        lock.withLock { wake = nil; pending.removeAll(); pendingWakes.removeAll() }
        let retired = hosts
        hosts.removeAll()
        for host in retired.values { host.close() }
    }
}

// Unmapped native surfaces may have no drawable. Render the full-size prewarm
// frame on this same device, preserving the framebuffer for the next native draw.
extension PortableGLRenderer {
    func withOverlayPrewarmTarget(width: Int, height: Int, draw: () throws -> Void) throws {
        guard let handle else { throw RenderError("The overlay renderer is closed") }
        guard let width = Int32(exactly: width), let height = Int32(exactly: height), width > 0, height > 0 else {
            throw RenderError("Invalid overlay prewarm dimensions")
        }
        var error = [CChar](repeating: 0, count: 512)
        guard let pass = rune_gl_pass_open(resolver, &error, 512) else {
            throw RenderError(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        defer { rune_gl_pass_close(pass) }
        let previous = rune_gl_draw_framebuffer(handle)
        var target = RuneGLPassTarget()
        guard rune_gl_pass_target(pass, RuneGLPassRGBA8, width, height, 0, &target, &error, 512) != 0 else {
            throw RenderError(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        defer { rune_gl_bind_draw_framebuffer(handle, previous); rune_gl_pass_delete_target(pass, &target) }
        rune_gl_bind_draw_framebuffer(handle, target.framebuffer)
        try draw()
    }
}
#endif
