#if canImport(Metal)
import Foundation
import Metal
#if os(macOS)
import AppKit
import CoreGraphics
#endif

enum MetalAdapterPicker {
    /// A caller-provided device always bypasses this default selection.
    static func select(displayID: UInt32? = nil) -> MTLDevice? {
        #if os(macOS)
        let env = ProcessInfo.processInfo.environment
        #if arch(x86_64)
        let devices = MTLCopyAllDevices().filter { displayID == nil || !$0.isHeadless }
        #else
        let devices = MTLCopyAllDevices()
        #endif
        if let name = env["WGPU_ADAPTER_NAME"]?.lowercased(),
           let selected = devices.first(where: { name.isEmpty || $0.name.lowercased().contains(name) }) {
            return selected
        }
        let connected = displayID.flatMap(CGDirectDisplayCopyCurrentMetalDevice)
        let system = MTLCreateSystemDefaultDevice()
        #if arch(x86_64)
        // Intel Macs can have separate low and high power devices, including external GPUs.
        switch env["WGPU_POWER_PREF"]?.lowercased() {
        case "high": return devices.first(where: { !$0.isLowPower }) ?? connected ?? system
        case "low": return devices.first(where: { $0.isLowPower }) ?? connected ?? system
        case "none": return system ?? devices.first
        default: return connected ?? devices.first(where: { $0.isLowPower }) ?? system ?? devices.first
        }
        #else
        return connected ?? system ?? devices.first
        #endif
        #else
        return MTLCreateSystemDefaultDevice()
        #endif
    }

    #if os(macOS)
    @MainActor
    static func forScreen(_ screen: NSScreen?) -> MTLDevice? {
        let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return select(displayID: id?.uint32Value ?? CGMainDisplayID())
    }
    #endif
}
#endif
