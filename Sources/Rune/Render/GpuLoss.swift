import Foundation

#if canImport(Metal)
@preconcurrency import Metal
#endif

/// Constants matching `crates/rune/src/render/gpu_loss.rs`.
public enum GpuLossConstants {
    public static let printedLimit: Int = 16
}

/// Tracks device loss and bounded uncaptured GPU errors (`crates/rune/src/render/gpu_loss.rs`).
public final class GpuDeviceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lost: Bool = false
    private var lostReason: String?
    private var totalErrors: Int = 0
    private var printedErrors: Int = 0
    private var mutedNoticeEmitted: Bool = false
    private var lastMessage: String?

    #if canImport(Metal)
    public let device: MTLDevice?

    public init(device: MTLDevice? = nil) {
        self.device = device
    }
    #else
    public init() {}
    #endif

    /// Whether the tracked GPU device has experienced a fatal/lost condition.
    public var isLost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lost
    }

    /// Total uncaptured GPU errors observed on this tracker.
    public var uncapturedErrorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalErrors
    }

    /// Number of uncaptured errors actually printed (capped at `GpuLossConstants.printedLimit = 16`).
    public var printedErrorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return printedErrors
    }

    /// Whether further error printing has been muted after hitting `printedLimit`.
    public var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutedNoticeEmitted
    }

    /// Most recent error description recorded on this tracker.
    public var lastErrorDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastMessage
    }

    /// Reason recorded when `markLost(reason:)` was triggered.
    public var lossReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return lostReason
    }

    /// Marks the device as lost (idempotent).
    public func markLost(reason: String? = nil) {
        lock.lock()
        if !lost {
            lost = true
            lostReason = reason
        }
        lock.unlock()
    }

    /// Records an uncaptured GPU error with bounded logging (`printedLimit = 16`).
    /// Returns `true` if this error was within the printed cap.
    @discardableResult
    public func recordUncapturedError(
        kind: String = "metal",
        message: String,
        marksLost: Bool = false,
        emitToStderr: Bool = false
    ) -> Bool {
        lock.lock()
        totalErrors += 1
        lastMessage = message
        if marksLost && !lost {
            lost = true
            lostReason = message
        }

        let printed: Bool
        var emitLine: String?
        if printedErrors < GpuLossConstants.printedLimit {
            printedErrors += 1
            printed = true
            if emitToStderr {
                emitLine = "rune: uncaptured \(kind) GPU error (\(printedErrors)/\(GpuLossConstants.printedLimit)): \(message)\n"
            }
        } else {
            printed = false
            if !mutedNoticeEmitted {
                mutedNoticeEmitted = true
                if emitToStderr {
                    emitLine = "rune: further uncaptured GPU errors muted (lost=\(lost))\n"
                }
            }
        }
        lock.unlock()

        if let emitLine {
            fputs(emitLine, stderr)
        }
        return printed
    }

    #if canImport(Metal)
    /// Attaches a completion handler to `commandBuffer` to capture command buffer execution failures and device-loss codes.
    public func attach(to commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self] buf in
            guard let self, let err = buf.error else { return }
            let nsErr = err as NSError
            let fatal: Bool
            if nsErr.domain == MTLCommandBufferErrorDomain,
               let code = MTLCommandBufferError.Code(rawValue: UInt(nsErr.code)) {
                switch code {
                case .internal, .timeout, .pageFault, .blacklisted, .notPermitted, .outOfMemory, .accessRevoked:
                    fatal = true
                default:
                    fatal = false
                }
            } else {
                fatal = false
            }
            self.recordUncapturedError(
                kind: "commandBuffer(\(nsErr.code))",
                message: nsErr.localizedDescription,
                marksLost: fatal,
                emitToStderr: false
            )
        }
    }
    #endif

    /// Resets tracker state (for tests).
    public func resetForTesting() {
        lock.lock()
        lost = false
        lostReason = nil
        totalErrors = 0
        printedErrors = 0
        mutedNoticeEmitted = false
        lastMessage = nil
        lock.unlock()
    }
}
