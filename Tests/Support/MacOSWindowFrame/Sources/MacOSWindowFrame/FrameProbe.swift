import AppKit
import QuartzCore
import Rune
import RuneMotion

// Run in a macOS graphical session with xcrun swift run --package-path Tests/Support/MacOSWindowFrame.
// Each case gets its own NSApplication event loop and observes its own real, decorated window.
@main @MainActor
enum FrameProbe {
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
        exit(1)
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        if (3...4).contains(arguments.count), arguments[1] == "wheel" {
            let zoom = arguments.count == 4 ? Float(arguments[3]) : 1
            guard let zoom, (0.1...10).contains(zoom) else { fail("Expected page zoom in 0.1...10") }
            try WheelPhaseProbe.run(host: arguments[2], zoom: zoom)
            return
        }
        if arguments.count == 4, arguments[1] == "shell" {
            try ShellProbe.run(host: arguments[2], kind: arguments[3])
            return
        }
        if arguments.count == 1 {
            for host in ["single", "grouped"] {
                for mode in ["motion", "reduced"] {
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: arguments[0])
                    child.arguments = [host, mode]
                    child.environment = ProcessInfo.processInfo.environment.merging(["RUNE_OPEN_INACTIVE": "1"]) { _, new in new }
                    let output = Pipe()
                    child.standardOutput = output
                    try child.run()
                    let result = output.fileHandleForReading.readDataToEndOfFile()
                    child.waitUntilExit()
                    FileHandle.standardOutput.write(result)
                    let receipt = "PASS \(host) \(mode)"
                    guard child.terminationStatus == 0, String(decoding: result, as: UTF8.self).split(separator: "\n").contains(Substring(receipt)) else {
                        fail("\(host) \(mode) exited \(child.terminationStatus) without its completion receipt")
                    }
                }
            }
            return
        }
        guard arguments.count == 3, ["single", "grouped"].contains(arguments[1]),
              ["motion", "reduced"].contains(arguments[2]) else { fail("Expected single|grouped motion|reduced") }
        let host = arguments[1]
        let reduced = arguments[2] == "reduced"
        let title = "Rune window frames \(host) \(getpid())"
        let probe = Observations()
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
            FileHandle.standardError.write(Data("FAIL \(host) timed out\n".utf8))
            exit(1)
        }
        let options = WindowOptions(minSize: Vec2(240, 140), maxSize: Vec2(500, 340), alwaysOnTop: true)
        let app = App(title: title, size: Vec2(300, 200), state: 0) { _, _ in text("Window frame probe") }
            .windowOptions(options).openInactive().accessory().keepRunning()
            .onFrameDrawn { runtime in
                MainActor.assumeIsolated { probe.sample(runtime) }
            }
            .onReady { handle in
                Task { @MainActor in
                    guard let window = NSApp.windows.first(where: { $0.title == title }) else { fail("Missing native window") }
                    probe.window = window
                    await probe.check(handle, reduced: reduced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    print("PASS \(host) \(arguments[2])")
                    exit(0)
                }
            }
        let launch = ["--time-scale", "0.28"] + (reduced ? ["--reduced-motion"] : [])
        if host == "single" {
            try app.run(arguments: launch)
        } else {
            try RuneMultiWindow.runWindows([AppWindowSpec(app: app).boxed()], options: RunOptions(accessory: true), arguments: launch)
        }
    }

    @MainActor
    private final class Observations {
        struct Sample {
            let time: Double
            let size: CGSize
            let synchronized: Bool
        }
        var window: NSWindow!
        var samples: [Sample] = []

        weak var metalLayer: CAMetalLayer?

        func sample(_ runtime: Runtime<Int>) {
            guard let window else { return }
            let size = window.contentRect(forFrameRect: window.frame).size
            guard abs(Float(size.width) - runtime.viewport.x) <= 0.5,
                  abs(Float(size.height) - runtime.viewport.y) <= 0.5 else {
                fail("Presented Rune viewport \(runtime.viewport) disagrees with native content \(size)")
            }
            samples.append(Sample(time: runtime.currentTime, size: size, synchronized: metalLayer?.presentsWithTransaction == true))
        }

        private var size: CGSize { window.contentRect(forFrameRect: window.frame).size }

        private func wait(_ label: String, until predicate: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !predicate() {
                if ContinuousClock.now >= deadline { fail("\(label) timed out at native frame \(window.frame)") }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        private func expectSize(_ width: Int, _ height: Int) async {
            let target = CGSize(width: width, height: height)
            await wait("content size \(target)") { self.size == target }
        }

        // Fit only the start time: the native host chooses the display tick at which a request starts.
        // All other spring parameters and each observation's timestamp come from Rune.
        private func springStart(from: Float, to: Float, axis: KeyPath<CGSize, CGFloat>, samples: [Sample]) -> Double {
            let intermediate = samples.filter {
                let fraction = (Float($0.size[keyPath: axis]) - from) / (to - from)
                return fraction > 0.06 && fraction < 0.94
            }
            guard intermediate.count >= 4, let first = intermediate.first else {
                fail("Only \(intermediate.count) intermediate spring samples on \(axis)")
            }
            var bestError = Float.infinity
            var bestStart = first.time
            for offset in 0...800 {
                let start = first.time - Double(offset) / 4_000
                let error = intermediate.reduce(Float.zero) { worst, sample in
                    let position = MotionTokens.DEFAULT.sample(from: from, velocity: 0, target: to,
                                                               at: Float(sample.time - start)).position
                    return max(worst, abs(position - Float(sample.size[keyPath: axis])))
                }
                if error < bestError {
                    bestStart = start
                    bestError = error
                }
            }
            guard bestError < 2 else { fail("Native spring differs by \(bestError)pt from Rune across \(intermediate.count) samples") }
            return bestStart
        }

        func check(_ handle: WindowHandle, reduced: Bool) async {
            guard let visible = window.screen?.visibleFrame else { fail("Window has no screen") }
            func metal(in view: NSView?) -> CAMetalLayer? {
                guard let view else { return nil }
                if let layer = view.layer as? CAMetalLayer { return layer }
                return view.subviews.lazy.compactMap { metal(in: $0) }.first
            }
            guard let layer = metal(in: window.contentView) else { fail("Hosted Rune window has no Metal layer") }
            metalLayer = layer
            // Leave room to grow down and to the right without touching a screen edge.
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 18, y: visible.maxY - 18))
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            handle.resizeInstant((260, 185))
            await expectSize(260, 185)

            samples.removeAll()
            handle.resize((720, 100))
            await expectSize(500, 140)
            guard window.frame.minX == topLeft.x, window.frame.maxY == topLeft.y else { fail("Resize moved the top-left corner") }
            if reduced {
                if samples.contains(where: { $0.size.width > 260 && $0.size.width < 500 }) { fail("Reduced motion animated") }
            } else {
                _ = springStart(from: 260, to: 500, axis: \.width, samples: samples)
                guard samples.filter({ $0.size.width > 260 && $0.size.width < 500 }).allSatisfy(\.synchronized) else {
                    fail("A visible intermediate spring frame was presented outside the AppKit transaction")
                }
            }
            // Wait for the final subpixel settling before the next independent resize.
            try? await Task.sleep(for: .milliseconds(200))
            await wait("resting layer to release transaction presentation") { !layer.presentsWithTransaction }
            samples.removeAll()
            handle.resizeInstant((260, 190))
            await expectSize(260, 190)
            if samples.contains(where: { $0.size.width > 260 && $0.size.width < 500 }) { fail("resizeInstant animated") }

            if !reduced {
                samples.removeAll()
                handle.resize((490, 190))
                await wait("intermediate width before retarget") { self.size.width >= 355 && self.size.width < 490 }
                let first = samples
                handle.resize((245, 300))
                await expectSize(245, 300)
                let firstStart = springStart(from: 260, to: 490, axis: \.width, samples: first)
                let secondStart = springStart(from: 190, to: 300, axis: \.height, samples: samples)
                let spring = MotionTokens.DEFAULT
                let initial = spring.sample(from: 260, velocity: 0, target: 490, at: Float(secondStart - firstStart))
                let retargeted = samples.filter { $0.size.height > 198 && $0.size.height < 290 }
                let error = retargeted.reduce(Float.zero) { worst, sample in
                    let width = spring.sample(from: initial.position, velocity: initial.velocity, target: 245,
                                              at: Float(sample.time - secondStart)).position
                    return max(worst, abs(width - Float(sample.size.width)))
                }
                guard retargeted.count >= 4, error < 3 else { fail("Retargeted width differs by \(error)pt across \(retargeted.count) samples") }
                print("PASS default spring and retargeted velocity across \(retargeted.count) native frames")
                try? await Task.sleep(for: .milliseconds(200))
            }
            let before = window.frame
            let x = visible.minX + floor((visible.width - before.width) / 2)
            let top = visible.maxY - floor((visible.height - before.height) / 4)
            handle.center()
            await wait("quarter-height centering") {
                abs(self.window.frame.minX - x) < 1 && abs(self.window.frame.maxY - top) < 1 && self.window.frame.size == before.size
            }
            handle.hide()
            await wait("hidden native window") { !self.window.isVisible }
            samples.removeAll()
            handle.resize((420, 250))
            await expectSize(420, 250)
            guard !window.isVisible else { fail("Resizing revealed a hidden window") }
            print("PASS clamped and instant sizes, visible-frame centering, hidden resize")
        }
    }
}
