import Foundation
#if canImport(Metal)
@preconcurrency import Metal
import Dispatch
#endif

/// Wait behavior for `Health.poll`, matching `wgpu::PollType`.
public enum PollMode: Sendable, Equatable, Hashable {
    /// Non-blocking poll of device completion state (`wgpu::PollType::Poll`).
    case poll
    /// Blocks until the queued work completes or the device is lost (`wgpu::PollType::wait_indefinitely()`).
    case waitIndefinitely
    /// Waits up to `timeoutSeconds` for completion (`wgpu::PollType::Wait`).
    case wait(timeoutSeconds: Double)
}

/// Outcome returned by `Health.poll`, matching `wgpu::PollStatus`.
public enum PollStatus: Sendable, Equatable, Hashable {
    /// All submitted work has completed.
    case queueEmpty
    /// Non-blocking poll completed while work is still in flight.
    case poll
    /// A blocking wait finished because the submission completed.
    case waitSucceeded
}

/// Non-fatal wait error returned inside `PollFailed.wait`, matching `wgpu::PollError`.
public enum PollWaitError: Error, Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The bounded wait timed out before the submission completed.
    case timeout
    /// The wait referenced a submission that was never committed to the queue.
    case unknownSubmissionIndex
    /// Backend-specific wait failure description.
    case failed(String)

    public var description: String {
        switch self {
        case .timeout:
            return "poll timed out"
        case .unknownSubmissionIndex:
            return "unknown submission index"
        case .failed(let message):
            return message
        }
    }
}

/// Why `Health.poll` gave no status, matching `rune_staging::health::PollFailed`.
public enum PollFailed: Error, Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The device is gone: nothing it was given will finish.
    case lost
    /// The wait timed out, or named a submission the queue never had.
    case wait(PollWaitError)

    public var description: String {
        switch self {
        case .lost:
            return "the GPU device was lost"
        case .wait(let error):
            return error.description
        }
    }
}

/// Cross-platform GPU device abstraction for `Health.removed` and `Health.poll`.
public protocol GPUHealthDevice: Sendable {
    /// Whether the underlying GPU device has been removed (TDR reset, driver update, unplug).
    var isDeviceRemoved: Bool { get }
    /// Polls or waits on device progress according to `mode`.
    func pollDevice(_ mode: PollMode) throws -> PollStatus
}

public extension GPUHealthDevice {
    var isDeviceRemoved: Bool { false }
}

/// The one wait on the GPU every Rune crate uses (mirrors `rune_staging::health`):
/// a lost or removed device is always reported as `PollFailed.lost`, never a hang or crash.
public enum Health: Sendable {
    public typealias PollFailed = RuneStaging.PollFailed
    public typealias PollMode = RuneStaging.PollMode
    public typealias PollStatus = RuneStaging.PollStatus
    public typealias PollWaitError = RuneStaging.PollWaitError

    /// Whether `device`'s GPU was removed (a reset after a timeout, a driver update, or an
    /// unplugged GPU). Matches `rune_staging::health::removed`.
    @inline(__always)
    public static func removed(_ device: any GPUHealthDevice) -> Bool {
        device.isDeviceRemoved
    }

    /// Polls `device`, translating a removed device or device-lost poll error into
    /// `PollFailed.lost` and non-fatal wait errors into `PollFailed.wait`.
    public static func poll(
        _ device: any GPUHealthDevice,
        mode: PollMode = .waitIndefinitely
    ) -> Result<PollStatus, PollFailed> {
        if removed(device) {
            return .failure(.lost)
        }
        do {
            let status = try device.pollDevice(mode)
            return .success(status)
        } catch let failed as PollFailed {
            if removed(device) {
                return .failure(.lost)
            }
            return .failure(failed)
        } catch let waitError as PollWaitError {
            if removed(device) {
                return .failure(.lost)
            }
            return .failure(.wait(waitError))
        } catch {
            if removed(device) || isDevicePollLostMessage(String(describing: error)) {
                return .failure(.lost)
            }
            return .failure(.wait(.failed(String(describing: error))))
        }
    }

    @inline(__always)
    internal static func isDevicePollLostMessage(_ message: String) -> Bool {
        message.hasPrefix("Error in Device::poll") || message.contains("Parent device is lost")
    }
}

#if canImport(Metal)
private final class SendableCommandBufferBox: @unchecked Sendable {
    let commandBuffer: MTLCommandBuffer
    init(_ commandBuffer: MTLCommandBuffer) {
        self.commandBuffer = commandBuffer
    }
}

public extension Health {
    /// Whether `device`'s GPU was removed. Matches `rune_staging::health::removed`:
    /// `false` on non-Windows backends (Metal surfaces device removal via command buffer
    /// completion errors rather than a synchronous device-removed status query).
    @inline(__always)
    static func removed(_ device: MTLDevice) -> Bool {
        _ = device
        return false
    }

    /// Waits for or checks `commandBuffer`, translating device removal / access revocation into
    /// `PollFailed.lost` and timeouts or uncommitted buffers into `PollFailed.wait(...)`.
    static func poll(
        commandBuffer: MTLCommandBuffer,
        mode: PollMode = .waitIndefinitely
    ) -> Result<PollStatus, PollFailed> {
        if removed(commandBuffer.device) {
            return .failure(.lost)
        }
        switch mode {
        case .poll:
            switch commandBuffer.status {
            case .completed:
                return .success(.queueEmpty)
            case .error:
                return .failure(classifyMetalError(commandBuffer.error))
            default:
                return .success(.poll)
            }

        case .waitIndefinitely:
            switch commandBuffer.status {
            case .completed:
                return .success(.waitSucceeded)
            case .error:
                return .failure(classifyMetalError(commandBuffer.error))
            case .notEnqueued, .enqueued:
                return .failure(.wait(.unknownSubmissionIndex))
            default:
                commandBuffer.waitUntilCompleted()
                if removed(commandBuffer.device) {
                    return .failure(.lost)
                }
                if commandBuffer.status == .completed {
                    return .success(.waitSucceeded)
                }
                return .failure(classifyMetalError(commandBuffer.error))
            }

        case .wait(let timeoutSeconds):
            switch commandBuffer.status {
            case .completed:
                return .success(.waitSucceeded)
            case .error:
                return .failure(classifyMetalError(commandBuffer.error))
            case .notEnqueued, .enqueued:
                return .failure(.wait(.unknownSubmissionIndex))
            default:
                break
            }
            if timeoutSeconds <= 0 {
                return .failure(.wait(.timeout))
            }
            let sem = DispatchSemaphore(value: 0)
            let box = SendableCommandBufferBox(commandBuffer)
            DispatchQueue.global(qos: .userInitiated).async {
                box.commandBuffer.waitUntilCompleted()
                sem.signal()
            }
            let waitResult = sem.wait(timeout: .now() + timeoutSeconds)
            if removed(commandBuffer.device) {
                return .failure(.lost)
            }
            if commandBuffer.status == .completed {
                return .success(.waitSucceeded)
            }
            if commandBuffer.status == .error {
                return .failure(classifyMetalError(commandBuffer.error))
            }
            if waitResult == .timedOut {
                return .failure(.wait(.timeout))
            }
            return .failure(classifyMetalError(commandBuffer.error))
        }
    }

    internal static func classifyMetalError(_ error: (any Error)?) -> PollFailed {
        guard let nsError = error as NSError? else {
            return .lost
        }
        if nsError.domain == MTLCommandBufferErrorDomain {
            // Raw value 11 = MTLCommandBufferErrorDeviceRemoved (unavailable on iOS, deprecated on Apple Silicon).
            if nsError.code == 11 || nsError.code == Int(MTLCommandBufferError.accessRevoked.rawValue) {
                return .lost
            }
            if nsError.code == Int(MTLCommandBufferError.timeout.rawValue) {
                return .wait(.timeout)
            }
        }
        if isDevicePollLostMessage(nsError.localizedDescription) {
            return .lost
        }
        return .wait(.failed(nsError.localizedDescription))
    }
}
#endif
