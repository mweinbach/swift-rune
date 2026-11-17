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

@objc(ProbeScene) @MainActor final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { exit(1) }
        let window = UIWindow(windowScene: scene)
        self.window = window
        DispatchQueue.main.async {
            do {
                try verify(window: window)
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
