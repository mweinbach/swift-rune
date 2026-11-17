import Foundation

#if canImport(Metal)
@preconcurrency import Metal
#endif

/// Timing constants for parked/lingering warmed GPUs (`crates/rune/src/render/warm.rs`).
public enum GpuWarmPolicy {
    public static let lingerDuration: TimeInterval = 30.0
    public static let parkedDuration: TimeInterval = 300.0
}

/// State of a macOS GPU prewarm slot (`crates/rune/src/render/prewarm.rs`).
public enum PrewarmSlotState: Sendable, Equatable {
    case idle
    case running
    case done
}

#if canImport(Metal)
/// Warmed Metal device + queue + health tracker ready for window surfacing (`warm.rs` + `warmup.rs`).
public final class WarmedGpuHandle: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let tracker: GpuDeviceTracker
    public let pixelFormat: MTLPixelFormat
    public let warmedAt: Date
    public let librariesWarmed: Int

    public init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        tracker: GpuDeviceTracker,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        warmedAt: Date = Date(),
        librariesWarmed: Int = 0
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.tracker = tracker
        self.pixelFormat = pixelFormat
        self.warmedAt = warmedAt
        self.librariesWarmed = librariesWarmed
    }

    public var isAlive: Bool {
        !tracker.isLost
    }
}

/// Asynchronous prewarm slot matching `render/prewarm.rs`'s `Slot` (`Idle` / `Running` / `Done`).
public final class PrewarmSlot: @unchecked Sendable {
    private let cond = NSCondition()
    private var currentState: PrewarmSlotState = .idle
    private var slotGeneration: UInt64 = 0
    private var result: WarmedGpuHandle?

    public init() {}

    public var state: PrewarmSlotState {
        cond.lock()
        defer { cond.unlock() }
        return currentState
    }

    /// Starts prewarming in the background if currently `.idle`.
    public func start(
        device: MTLDevice? = nil,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        emitEvents: Bool = false
    ) {
        cond.lock()
        guard currentState == .idle else {
            cond.unlock()
            return
        }
        slotGeneration &+= 1
        let myGen = slotGeneration
        currentState = .running
        result = nil
        cond.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let warmed = WarmGpuCoordinator.warmSynchronously(
                device: device,
                pixelFormat: pixelFormat,
                emitEvents: emitEvents
            )
            guard let self else { return }
            self.cond.lock()
            if self.slotGeneration == myGen && self.currentState == .running {
                self.result = warmed
                self.currentState = warmed != nil ? .done : .idle
            }
            self.cond.broadcast()
            self.cond.unlock()
        }
    }

    /// Takes the warmed GPU handle (waiting if currently `.running` per `prewarm.rs::Slot::take`), resetting the slot to `.idle`.
    public func take() -> WarmedGpuHandle? {
        cond.lock()
        let waitGen = slotGeneration
        while currentState == .running && slotGeneration == waitGen {
            cond.wait()
        }
        guard slotGeneration == waitGen, currentState == .done else {
            cond.unlock()
            return nil
        }
        let handle = result
        result = nil
        currentState = .idle
        cond.unlock()
        if let handle, !handle.isAlive {
            return nil
        }
        return handle
    }

    /// Discards any in-flight or completed handle and starts a fresh warm-up.
    public func restart(
        device: MTLDevice? = nil,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        emitEvents: Bool = false
    ) {
        discard()
        start(device: device, pixelFormat: pixelFormat, emitEvents: emitEvents)
    }

    /// Invalidates any in-flight or completed handle and returns to `.idle`.
    public func discard() {
        cond.lock()
        slotGeneration &+= 1
        result = nil
        currentState = .idle
        cond.broadcast()
        cond.unlock()
    }

    /// Waits up to `timeout` seconds for an active `.running` warm-up to settle (for deterministic tests).
    @discardableResult
    public func waitUntilSettled(timeout: TimeInterval = 5.0) -> PrewarmSlotState {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        cond.lock()
        while currentState == .running {
            if !cond.wait(until: deadline) {
                break
            }
        }
        let s = currentState
        cond.unlock()
        return s
    }
}

/// Manages parked/lingering GPU warm state (`warm_gpu`, `warm_gpu_with`, `surface_gpu`, `park_gpu`).
public final class WarmGpuCoordinator: @unchecked Sendable {
    public static let shared = WarmGpuCoordinator()

    private struct ParkedEntry {
        let handle: WarmedGpuHandle
        let parkedAt: Date
        let expiresAt: Date
    }

    private let cond = NSCondition()
    private var parked: ParkedEntry?
    private var parkGeneration: UInt64 = 0
    private var makingUntil: Date?
    private var pendingCompletions: [@Sendable (WarmedGpuHandle?) -> Void] = []
    private let prewarmSlot = PrewarmSlot()

    public init() {}

    /// Synchronously warms `device` (precompiled metallib load + 8x8 offscreen clear pass).
    @discardableResult
    public static func warmSynchronously(
        device preferredDevice: MTLDevice? = nil,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        emitEvents: Bool = true
    ) -> WarmedGpuHandle? {
        if emitEvents {
            GpuEvents.starting()
        }
        guard let dev = preferredDevice ?? MetalAdapterPicker.select(),
              let queue = dev.makeCommandQueue() else {
            return nil
        }

        let tracker = GpuDeviceTracker(device: dev)

        // Warm core shader libraries (prefers precompiled `.metallib` when bundled & fresh).
        var loaded = 0
        for entry in PrecompiledMetallib.builtinEntries {
            if (try? ShaderLibraryCache.load(
                named: entry.name,
                source: entry.source,
                requiredFunction: entry.requiredFunction,
                bundle: PrecompiledMetallib.runeResourceBundle,
                on: dev
            )) != nil {
                loaded += 1
            }
        }

        // Encode and commit an 8x8 offscreen clear pass matching `warm.rs` warmup pass.
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: 8,
            height: 8,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget]
        texDesc.storageMode = .private
        if let tex = dev.makeTexture(descriptor: texDesc),
           let cmdBuf = queue.makeCommandBuffer() {
            tracker.attach(to: cmdBuf)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.colorAttachments[0].storeAction = .store
            if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) {
                enc.endEncoding()
            }
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
        }

        if emitEvents {
            GpuEvents.presented()
        }

        guard !tracker.isLost else { return nil }
        return WarmedGpuHandle(
            device: dev,
            commandQueue: queue,
            tracker: tracker,
            pixelFormat: pixelFormat,
            warmedAt: Date(),
            librariesWarmed: loaded
        )
    }

    /// Warms a GPU on a background queue and parks it for `GpuWarmPolicy.lingerDuration` (30s) for `surfaceGpu()`.
    public func warmGpu(
        device: MTLDevice? = nil,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        emitEvents: Bool = true
    ) {
        warmGpuWith(device: device, pixelFormat: pixelFormat, emitEvents: emitEvents, completion: nil)
    }

    /// Warms a GPU on a background queue, parks it for `lingerDuration` if alive (extending TTL if already warm/making), and invokes `completion`.
    public func warmGpuWith(
        device: MTLDevice? = nil,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        emitEvents: Bool = true,
        at now: Date = Date(),
        completion: (@Sendable (WarmedGpuHandle?) -> Void)?
    ) {
        let until = now.addingTimeInterval(GpuWarmPolicy.lingerDuration)
        cond.lock()
        if let entry = parked, entry.handle.isAlive, now <= entry.expiresAt {
            let extended = max(entry.expiresAt, until)
            parkGeneration &+= 1
            let gen = parkGeneration
            parked = ParkedEntry(handle: entry.handle, parkedAt: entry.parkedAt, expiresAt: extended)
            cond.unlock()
            if abs(now.timeIntervalSinceNow) < 5.0 {
                scheduleExpirySweep(at: extended, generation: gen)
            }
            completion?(entry.handle)
            return
        }
        parked = nil
        if let currentUntil = makingUntil {
            makingUntil = max(currentUntil, until)
            if let completion {
                pendingCompletions.append(completion)
            }
            cond.unlock()
            return
        }
        makingUntil = until
        let myWarmGen = parkGeneration &+ 1
        parkGeneration = myWarmGen
        if let completion {
            pendingCompletions.append(completion)
        }
        cond.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = Self.warmSynchronously(
                device: device,
                pixelFormat: pixelFormat,
                emitEvents: emitEvents
            )
            guard let self else {
                completion?(handle)
                return
            }
            self.cond.lock()
            let deadline = self.makingUntil
            self.makingUntil = nil
            let callbacks = self.pendingCompletions
            self.pendingCompletions.removeAll()
            var expireAt: Date?
            var expireGen: UInt64 = 0
            if let handle, handle.isAlive, let deadline {
                self.parkGeneration &+= 1
                expireGen = self.parkGeneration
                self.parked = ParkedEntry(handle: handle, parkedAt: now, expiresAt: deadline)
                if abs(now.timeIntervalSinceNow) < 5.0 {
                    expireAt = deadline
                }
            }
            self.cond.broadcast()
            self.cond.unlock()

            if let expireAt {
                self.scheduleExpirySweep(at: expireAt, generation: expireGen)
            }
            for cb in callbacks {
                cb(handle)
            }
        }
    }

    private func scheduleExpirySweep(at expiresAt: Date, generation: UInt64) {
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.cond.lock()
            if self.parkGeneration == generation {
                self.parked = nil
            }
            self.cond.unlock()
        }
    }

    /// Parks an already-created GPU handle for reuse (`GpuWarmPolicy.parkedDuration = 300s` by default, or `linger`).
    public func parkGpu(
        _ handle: WarmedGpuHandle,
        at now: Date = Date(),
        linger: TimeInterval = GpuWarmPolicy.parkedDuration
    ) {
        guard handle.isAlive else { return }
        let expiresAt = now.addingTimeInterval(max(0, linger))
        cond.lock()
        parkGeneration &+= 1
        parked = ParkedEntry(handle: handle, parkedAt: now, expiresAt: expiresAt)
        cond.broadcast()
        cond.unlock()
    }

    /// Returns a parked (or prewarmed) GPU handle if alive and within its TTL, waiting if `warmGpu` is still running (`warm_tests.rs`).
    public func surfaceGpu(at now: Date = Date()) -> WarmedGpuHandle? {
        cond.lock()
        while makingUntil != nil {
            cond.wait()
        }
        if let entry = parked {
            parked = nil
            cond.unlock()
            if entry.handle.isAlive && now <= entry.expiresAt {
                return entry.handle
            }
            return nil
        }
        cond.unlock()
        return prewarmSlot.take()
    }

    /// Sweeps an expired or lost parked handle without returning it.
    public func sweepExpired(at now: Date = Date()) {
        cond.lock()
        if let entry = parked {
            if !entry.handle.isAlive || now > entry.expiresAt {
                parked = nil
            }
        }
        cond.unlock()
    }

    /// Access to the background prewarm slot.
    public var slot: PrewarmSlot { prewarmSlot }

    /// Clears any parked or prewarmed handle (for tests).
    public func resetForTesting() {
        cond.lock()
        parkGeneration &+= 1
        parked = nil
        makingUntil = nil
        let callbacks = pendingCompletions
        pendingCompletions.removeAll()
        cond.broadcast()
        cond.unlock()
        for cb in callbacks {
            cb(nil)
        }
        prewarmSlot.discard()
    }
}
#endif
