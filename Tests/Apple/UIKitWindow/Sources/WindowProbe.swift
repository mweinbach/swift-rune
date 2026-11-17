import Foundation
import Metal
import UIKit
@testable import Rune

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Snapshot {
    let width: Int
    let height: Int
    let pixels: [UInt32]
    let device: String
}

/// Read the presented color attachment after Rune's commands, on the same command buffer.
private final class DrawableCapture: Compositor {
    typealias State = HelloState
    private var submission: (MTLCommandBuffer, MTLBuffer, Int, Int, Int)?

    func render(frame: CompositorFrame<HelloState>) {
        frame.drawUI()
        guard let commands = frame.commandBuffer, let texture = frame.targetTexture else { return }
        let pitch = ((texture.width * 4 + 255) / 256) * 256
        guard let buffer = commands.device.makeBuffer(length: pitch * texture.height, options: .storageModeShared),
              let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: pitch,
                  destinationBytesPerImage: pitch * texture.height)
        blit.endEncoding()
        submission = (commands, buffer, texture.width, texture.height, pitch)
    }

    @MainActor func snapshot(_ view: RuneIOSView<HelloState>) throws -> Snapshot {
        submission = nil
        view.renderTick()
        guard let (command, buffer, width, height, pitch) = submission else {
            throw ProbeError("The UIKit host did not submit RuneHello to a Metal drawable")
        }
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw ProbeError("Metal command buffer failed: \(String(describing: command.error))")
        }
        let pixels = (0..<height).flatMap { row in
            let start = buffer.contents().advanced(by: row * pitch).assumingMemoryBound(to: UInt32.self)
            return Array(UnsafeBufferPointer(start: start, count: width))
        }
        return Snapshot(width: width, height: height, pixels: pixels, device: command.device.name)
    }
}

@MainActor private func verify(window: UIWindow) throws {
    let scene = RuneHelloScene.makeSpec()
    let capture = DrawableCapture()
    let app = App(title: scene.title, size: scene.size, state: scene.makeState(), view: scene.view)
        .gpuBackend(.metal).compositor(capture)
    let controller = try IOSApp.makeViewController(app)
    let view = controller.runeView
    view.frame = CGRect(x: 0, y: 0, width: CGFloat(scene.size.x), height: CGFloat(scene.size.y))
    window.addSubview(view)
    defer { view.removeFromSuperview() }
    view.layoutIfNeeded()

    let before = try capture.snapshot(view)
    guard let control = view.runtime.element(byKey: "switch"), control.rect.count == 4 else {
        throw ProbeError("RuneHello did not lay out its switch")
    }
    let rect = control.rect
    let center = Vec2(rect[0] + rect[2] / 2, rect[1] + rect[3] / 2)
    let t = view.runtime.currentTime
    // Deliver the same normalized contact as touchesBegan/touchesEnded without moving the user's pointer.
    view.deliverContact(id: 1, phase: .started, at: center, eventTimestamp: nil, time: t)
    view.deliverContact(id: 1, phase: .ended, at: center, eventTimestamp: nil, time: t)
    let after = try capture.snapshot(view)
    guard before.width == after.width, before.height == after.height else {
        throw ProbeError("The drawable changed size before resize")
    }
    let changed = zip(before.pixels, after.pixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    guard view.runtime.state.on, changed > 0 else { throw ProbeError("Toggle left the state or GPU pixels unchanged") }

    view.frame.size = CGSize(width: 460, height: 280)
    view.layoutIfNeeded()
    let resized = try capture.snapshot(view)
    guard resized.width == Int((view.bounds.width * view.contentScaleFactor).rounded()),
          resized.height == Int((view.bounds.height * view.contentScaleFactor).rounded()),
          resized.width > before.width, resized.height > before.height else {
        throw ProbeError("Unexpected resized drawable \(resized.width)×\(resized.height)")
    }
    print("RuneHello on \(after.device) changed \(changed) pixels after touch and resized from \(before.width)×\(before.height) to \(resized.width)×\(resized.height).")
}

private final class MovingContent: Compositor {
    var isAnimating = true
    func render(frame: CompositorFrame<Int>) { frame.drawUI() }
}

@MainActor private func verifyDisplayLink(_ window: UIWindow) async throws {
    let motion = MovingContent()
    var frames: [FrameEncoded] = []
    var ready: WindowHandle?
    var readyCount: UInt64 = 0
    var reportedInsets: [Float] = []
    let traceFile = FileManager.default.temporaryDirectory.appending(path: "rune-uikit-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: traceFile) }
    let frameLimit = 12
    let app = App(title: "Rune cadence", size: Vec2(40, 40), state: 0) { _, cx in
        reportedInsets = cx.safeArea()
        return text("Rune")
    }
        .gpuBackend(.metal).compositor(motion)
        .onFrameEncoded { if $0.outcome == .drawn { frames.append($0) } }
        .onReady { handle in
            readyCount = handle.surfaceStats.totals.presents
            ready = handle
        }
    let args = ToolingArgs.parse(["--native", "--trace", traceFile.path, "--frames", String(frameLimit)])
    let controller = try IOSApp.makeViewController(app, parsed: args)
    if let limits = window.windowScene?.sizeRestrictions {
        limits.minimumSize = CGSize(width: 40, height: 40)
        limits.maximumSize = CGSize(width: 40, height: 40)
    }
    window.rootViewController = controller
    window.isUserInteractionEnabled = false
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while frames.filter({ $0.presentsAt != nil }).count < 5 && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(15))
    }
    motion.isAnimating = false
    let paced = frames.filter { $0.presentsAt != nil }
    guard paced.count >= 5, let first = paced.first, let hz = first.refreshHz, hz > 0,
          paced.allSatisfy({ $0.started != nil && $0.at >= $0.started! && $0.refreshHz ?? 0 > 0 }),
          zip(paced, paced.dropFirst()).allSatisfy({ $0.presentsAt! < $1.presentsAt! }),
          let ready, readyCount > 0, ready.surfaceStats.totals.presents > readyCount,
          ready.surfaceStats.totals.presents == UInt64(frames.count), ready.surfaceStats.totals.turns > 0,
          ready.surfaceStats.totals == controller.runeView.runtime.surfaceStats()?.totals else {
        throw ProbeError("UIKit cadence mismatch: paced=\(paced.count), submitted=\(frames.count), ready=\(readyCount), stats=\(String(describing: ready?.surfaceStats))")
    }
    var traceSummary: TracePresentSummary?
    while clock.now < deadline {
        if let body = try? String(contentsOf: traceFile, encoding: .utf8),
           let summary = TracePresentSummary.ofTrace(body), summary.frames == frameLimit {
            traceSummary = summary
            break
        }
        try await Task.sleep(for: .milliseconds(15))
    }
    guard let traceSummary, traceSummary.presented >= 3, traceSummary.interval?.p50 ?? 0 > 0,
          traceSummary.lag != nil, controller.runeView.runtime.traceChannels == nil,
          !controller.runeView.runtime.urlOpener.headless else {
        throw ProbeError("The finite trace did not finish paced drawable capture and restore the embedded app")
    }
    print("UIKit trace: \(traceSummary.displayDescription)")
    if let copy = ProcessInfo.processInfo.environment["RUNE_UIKIT_TEST_TRACE"] {
        try Data(contentsOf: traceFile).write(to: URL(fileURLWithPath: copy), options: .atomic)
    }
    try await Task.sleep(for: .milliseconds(100))
    let idleCount = frames.count
    try await Task.sleep(for: .milliseconds(100))
    guard frames.count == idleCount else { throw ProbeError("The settled UIKit window kept submitting") }
    controller.runeView.runtime.waker.wake()
    let wakeDeadline = clock.now.advanced(by: .seconds(2))
    while frames.count == idleCount && clock.now < wakeDeadline { try await Task.sleep(for: .milliseconds(5)) }
    guard frames.count == idleCount + 1, frames.last?.presentsAt == nil else {
        throw ProbeError("A settled window wake did not submit exactly one immediate frame")
    }
    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 3, left: 4, bottom: 6, right: 5)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    controller.runeView.renderTick()
    let safe = controller.runeView.safeAreaInsets
    guard safe.bottom >= 6, reportedInsets == [safe.top, safe.right, safe.bottom, safe.left].map(Float.init) else {
        throw ProbeError("UIKit safe area failed to reach the view: \(safe), \(reportedInsets)")
    }
    print("UIKit submitted \(frames.count) frames. \(paced.count) had increasing display targets at \(String(format: "%.2f", hz)) Hz. The public window and runtime counted the same submissions.")
}

@objc(ProbeScene) @MainActor final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { exit(1) }
        let window = UIWindow(windowScene: scene)
        self.window = window
        Task { @MainActor in
            do {
                try verify(window: window)
                try await verifyDisplayLink(window)
                if let result = ProcessInfo.processInfo.environment["RUNE_UIKIT_TEST_RESULT"] {
                    try Data().write(to: URL(fileURLWithPath: result), options: .atomic)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
    }
}

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Probe", sessionRole: session.role)
        configuration.delegateClass = ProbeScene.self
        return configuration
    }
}
