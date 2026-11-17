#if os(Windows)
import Foundation
import Rune
import RuneMotion
import RuneRef
import WinSDK

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}

private final class Producer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(executable: URL, name: String, adapter: (high: Int32, low: UInt32)) throws {
        process.executableURL = executable
        process.arguments = [name, String(adapter.high), String(adapter.low)]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let greeting = try readLine()
        try require(greeting == "ready", "Unexpected producer greeting: \(greeting)")
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    private func readLine() throws -> String {
        var bytes = [UInt8]()
        while bytes.count < 128 {
            let data = output.fileHandleForReading.readData(ofLength: 1)
            guard let byte = data.first else { throw Failure("Producer closed its output") }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            if byte != 13 { bytes.append(byte) }
        }
        throw Failure("Producer sent an invalid response")
    }

    func expect(_ command: String, _ response: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        let actual = try readLine()
        try require(actual == response, "Producer answered \(actual) to \(command); expected \(response)")
    }

    func finish() throws {
        try expect("quit", "done")
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "Producer exited \(process.terminationStatus)")
    }
}

private typealias Pixel = SIMD4<UInt8>
private let firstImage: [Pixel] = [
    Pixel(255, 0, 0, 255), Pixel(0, 255, 0, 255),
    Pixel(0, 0, 255, 255), Pixel(255, 255, 0, 255)
]
private let secondImage: [Pixel] = [
    Pixel(0, 255, 255, 255), Pixel(255, 0, 255, 255),
    Pixel(255, 255, 255, 255), Pixel(0, 0, 0, 255)
]

private func verify(_ frame: Frame, _ quadrants: [Pixel], _ label: String, mirrored: Bool = false) throws {
    try require(frame.width == 4 && frame.height == 2, "\(label): wrong frame size")
    for y in 0..<2 {
        for x in 0..<4 {
            let expected = quadrants[2 * y + (mirrored ? 3 - x : x) / 2]
            let actual = frame.pixel(x: x, y: y)
            try require(actual == expected, "\(label) (\(x), \(y)): expected \(expected), got \(actual)")
        }
    }
}

@main
private enum Consumer {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("Shared texture test failed: \(error)\n".utf8))
            ExitProcess(1)
        }
    }

    private static func run() throws {
        let renderer = try OffscreenGPURenderer(reportAdapter: true)
        guard let adapter = SharedTexture.adapterLUID else { throw Failure("Missing Direct3D adapter LUID") }
        let executable: URL
        if CommandLine.arguments.count > 1 {
            executable = URL(fileURLWithPath: CommandLine.arguments[1])
        } else {
            executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("SharedTextureProducer.exe")
        }
        let prefix = "Local\\RuneSharedTexture-\(UUID().uuidString)"
        let producer = try Producer(executable: executable, name: prefix, adapter: adapter)
        let surface = NativeSurface()
        let ui = Runtime(state: false, viewport: Vec2(4, 2), pixelScale: 1) { _, _ in
            nativeSurface(surface, .stretch).size(4, 2).bg(Color(r: 1, g: 1, b: 1, a: 1))
        }
        let texture = SharedTexture.named(prefix + "-bgra", width: 4, height: 2)
        let fence = prefix + "-fence"
        func publish(_ descriptor: SharedTexture, _ ticket: UInt64) throws {
            // Deliberately reuse the external frame identifier. Each publication has its own pixels.
            try surface.pushShared(descriptor.releaseFence(fence, value: ticket), frameId: 42)
        }
        func draw(_ device: OffscreenGPURenderer) throws -> Frame {
            let frame = try device.frame(ui, at: 0)
            try require(frame.surfaces.count == 1, "Runtime did not emit the native surface")
            return try device.renderOffscreen(frame)
        }
        try publish(texture, 1)
        try publish(texture, 2)
        try producer.expect("value", "0")
        try verify(draw(renderer), firstImage, "first frame")
        try producer.expect("wait 2", "2")
        try producer.expect("overwrite", "overwritten")
        try verify(draw(renderer), firstImage, "redraw after release")
        var referenceArgs = ToolingArgs()
        referenceArgs.forceCPU = true
        referenceArgs.pixelScale = 1
        let spec = AppSpec(title: "Shared texture reference", size: Vec2(4, 2), state: false) { _, _ in
            nativeSurface(surface, .stretch).size(4, 2)
        }
        let reference = try HeadlessRunner.run(spec, args: referenceArgs)
        try verify(reference.finalFrame, firstImage, "reference readback after release")
        surface.setMirrored(true)
        try verify(draw(renderer), firstImage, "mirror", mirrored: true)
        surface.setMirrored(false)
        _ = try renderer.renderOffscreen(RefScene(width: 4, height: 2))
        try verify(draw(renderer), firstImage, "remount after release")
        do {
            let secondRenderer = try OffscreenGPURenderer()
            try verify(draw(secondRenderer), firstImage, "independent WGL context after release")
        }
        try publish(texture, 3)
        try verify(draw(renderer), secondImage, "republished frame")
        try producer.expect("wait 3", "3")

        for (ticket, descriptor) in [
            (UInt64(4), SharedTexture.named(prefix + "-absent", width: 4, height: 2)),
            (UInt64(5), SharedTexture.named(prefix + "-rgba", width: 4, height: 2)),
            (UInt64(6), SharedTexture.named(prefix + "-bgra", width: 2, height: 2))
        ] {
            try publish(descriptor, ticket)
            let skipped = try draw(renderer)
            try require(surface.lastError != nil, "Invalid import \(ticket) must report an error")
            try verify(skipped, [Pixel](repeating: Pixel(255, 255, 255, 255), count: 4), "skipped import")
            try producer.expect("wait \(ticket)", String(ticket))
        }
        try surface.pushShared(texture.releaseFence(prefix + "-absent-fence", value: 7), frameId: 42)
        let skipped = try draw(renderer)
        try require(surface.lastError != nil, "Unknown fence must report an error")
        try verify(skipped, [Pixel](repeating: Pixel(255, 255, 255, 255), count: 4), "missing fence")
        try producer.expect("value", "6")

        try publish(texture, 7)
        try verify(draw(renderer), secondImage, "recovery")
        try producer.expect("wait 7", "7")
        try require(surface.lastError == nil, "Recovery did not clear the last error")
        for descriptor in [SharedTexture.named(prefix, width: 0, height: 2),
                           SharedTexture.named(prefix, width: 4, height: 16_385),
                           SharedTexture.named("", width: 4, height: 2),
                           SharedTexture.named("nul\u{0}name", width: 4, height: 2)] {
            var rejected = false
            do { try surface.pushShared(descriptor, frameId: 43) } catch { rejected = true }
            try require(rejected && surface.currentFrame()?.id == 42, "Invalid publication replaced the last frame")
        }
        try surface.pushShared(texture, frameId: 44)
        try verify(draw(renderer), secondImage, "fence-free publication")
        try producer.expect("value", "7")
        try publish(SharedTexture.named(prefix + "-absent", width: 4, height: 2), 8)
        let skippedCPU = try HeadlessRunner.run(spec, args: referenceArgs).finalFrame
        try require(surface.lastError != nil && skippedCPU.pixel(x: 0, y: 0) != secondImage[0],
                    "Headless renderer did not skip the failed import")
        try producer.expect("wait 8", "8")
        try publish(texture, 9)
        try verify(HeadlessRunner.run(spec, args: referenceArgs).finalFrame, secondImage, "headless recovery")
        try producer.expect("wait 9", "9")
        try require(surface.lastError == nil, "Headless recovery did not clear the import error")
        try producer.finish()
        try validateWGLCompletions()
        try validateWGLAbandonment()
        let family = ProcessInfo.processInfo.environment["RUNE_TEST_D3D12_PRODUCER"] == nil ? "D3D11" : "D3D12"
        print("PASS: \(family) named texture and release fence across processes. Verified BGRA pixels, mirror, cached redraw, remount, second context, software readback, repeated frame ID, error release and recovery.")
    }
}
#else
@main private enum Consumer {
    static func main() { print("This integration test requires Windows.") }
}
#endif
