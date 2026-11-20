#if canImport(Metal)
import Foundation
import Metal
#if os(macOS)
import AppKit
import CoreGraphics
#endif

enum MetalAdapterPicker {
    /// Selects a Metal device following upstream `#1286`:
    /// - `WGPU_ADAPTER_NAME` is final: returns `.failure` (and logs `rune: no GPU: ...`) instead
    ///   of silently falling through to another GPU when no usable adapter matches.
    /// - Without overrides, every device (windows, overlays, offscreen renders and tests) picks
    ///   the GPU driving the target or primary display (`.display` when presented, `.windowGpu`
    ///   when offscreen/test), falling back to lowest power only when no display GPU exists.
    /// - `RUNE_GPU_LOG=1` logs every pick; without it, multi-GPU hosts log the first pick once.
    static func pick(
        displayID: UInt32? = nil,
        presented: Bool? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        logger: GpuPickLogger = .shared,
        sink: ((String) -> Void)? = nil
    ) -> Result<(device: MTLDevice, reason: GpuPickReason), GpuPickError> {
        let isPresented = presented ?? (displayID != nil)
        #if os(macOS)
        let allDevices = MTLCopyAllDevices()
        let targetDisplay = displayID ?? CGMainDisplayID()
        let primaryDisplayDevice = CGDirectDisplayCopyCurrentMetalDevice(targetDisplay)
        let primaryID = primaryDisplayDevice?.registryID

        let candidates: [GpuAdapterCandidate] = allDevices.map { dev in
            GpuAdapterCandidate(
                name: dev.name,
                backend: "Metal",
                deviceType: dev.isLowPower ? "IntegratedGpu" : "DiscreteGpu",
                isLowPower: dev.isLowPower,
                isHeadless: dev.isHeadless,
                isPrimaryDisplay: primaryID != nil && dev.registryID == primaryID,
                isCompositor: false,
                isSoftware: false,
                supportsSurface: !dev.isHeadless
            )
        }

        if !allDevices.isEmpty {
            switch GpuAdapterPicker.pick(candidates: candidates, presented: isPresented, env: env) {
            case let .success(outcome):
                let dev = allDevices[outcome.index]
                let candidate = candidates[outcome.index]
                logger.logPick(
                    name: dev.name,
                    backendLabel: "Rune's Metal backend",
                    backend: candidate.backend,
                    deviceType: candidate.deviceType,
                    reason: outcome.reason,
                    adapterCount: outcome.hardwareCount,
                    env: env,
                    sink: sink
                )
                return .success((dev, outcome.reason))
            case let .failure(error):
                logger.logFailure(error.description, sink: sink)
                return .failure(error)
            }
        }

        if let rawName = env["WGPU_ADAPTER_NAME"] {
            let error = GpuPickError.noMatch("no GPU adapter matches WGPU_ADAPTER_NAME=\"\(rawName)\"")
            logger.logFailure(error.description, sink: sink)
            return .failure(error)
        }
        if let dev = primaryDisplayDevice {
            let reason: GpuPickReason = isPresented ? .display : .windowGpu
            logger.logPick(
                name: dev.name,
                backendLabel: "Rune's Metal backend",
                backend: "Metal",
                deviceType: dev.isLowPower ? "IntegratedGpu" : "DiscreteGpu",
                reason: reason,
                adapterCount: 1,
                env: env,
                sink: sink
            )
            return .success((dev, reason))
        }
        if let system = MTLCreateSystemDefaultDevice() {
            logger.logPick(
                name: system.name,
                backendLabel: "Rune's Metal backend",
                backend: "Metal",
                deviceType: system.isLowPower ? "IntegratedGpu" : "DiscreteGpu",
                reason: .lowPower,
                adapterCount: 1,
                env: env,
                sink: sink
            )
            return .success((system, .lowPower))
        }
        let error = GpuPickError.noMatch("no usable Metal device found")
        logger.logFailure(error.description, sink: sink)
        return .failure(error)
        #else
        if let system = MTLCreateSystemDefaultDevice() {
            if let rawName = env["WGPU_ADAPTER_NAME"], !rawName.isEmpty,
               !system.name.lowercased().contains(rawName.lowercased()) {
                let error = GpuPickError.noMatch("no GPU adapter matches WGPU_ADAPTER_NAME=\"\(rawName)\"")
                logger.logFailure(error.description, sink: sink)
                return .failure(error)
            }
            let reason: GpuPickReason = env["WGPU_ADAPTER_NAME"] != nil ? .envName : (isPresented ? .display : .windowGpu)
            logger.logPick(
                name: system.name,
                backendLabel: "Rune's Metal backend",
                backend: "Metal",
                deviceType: "IntegratedGpu",
                reason: reason,
                adapterCount: 1,
                env: env,
                sink: sink
            )
            return .success((system, reason))
        }
        let error = GpuPickError.noMatch("no usable Metal device found")
        logger.logFailure(error.description, sink: sink)
        return .failure(error)
        #endif
    }

    /// A caller-provided device always bypasses this default selection.
    static func select(displayID: UInt32? = nil) -> MTLDevice? {
        switch pick(displayID: displayID) {
        case let .success(picked):
            return picked.device
        case .failure:
            return nil
        }
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
