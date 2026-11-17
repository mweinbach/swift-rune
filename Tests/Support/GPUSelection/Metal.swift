#if os(macOS)
import AppKit
import Metal
import QuartzCore

@main enum MetalProbe {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let screen = window.screen
        if CommandLine.arguments.contains("--named"), let candidate = MTLCopyAllDevices().first {
            setenv("WGPU_ADAPTER_NAME", candidate.name.uppercased(), 1)
        }
        guard let device = MetalAdapterPicker.forScreen(screen), let queue = device.makeCommandQueue() else { fatalError("missing device") }
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        guard let display = CGDirectDisplayCopyCurrentMetalDevice(displayID) else { fatalError("missing display device") }
        if let name = ProcessInfo.processInfo.environment["WGPU_ADAPTER_NAME"]?.lowercased(),
           let matching = MTLCopyAllDevices().first(where: { $0.name.lowercased() == name }) {
            precondition(matching.registryID == device.registryID)
        }
        // On a single-device machine all policies produce the same physical device.
        if MTLCopyAllDevices().count == 1 { precondition(device.registryID == display.registryID) }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.drawableSize = CGSize(width: 32, height: 32)
        let view = NSView(frame: window.contentView!.bounds)
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        guard let frame = layer.nextDrawable(), let command = queue.makeCommandBuffer(),
              let readback = device.makeBuffer(length: 256 * 32, options: .storageModeShared) else { fatalError("missing drawable") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = frame.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1)
        command.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
        let copy = command.makeBlitCommandEncoder()!
        copy.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: 1, height: 1, depth: 1), to: readback,
                  destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        copy.endEncoding()
        command.present(frame)
        command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed)
        let bgra = readback.contents().assumingMemoryBound(to: UInt8.self)
        precondition((bgra[0], bgra[1], bgra[2], bgra[3]) == (0, 0, 255, 255))
        print("Metal device \(device.name); registry \(device.registryID); display \(displayID); candidates \(MTLCopyAllDevices().count); submitted and read BGRA 0 0 255 255")
    }
}
#endif
