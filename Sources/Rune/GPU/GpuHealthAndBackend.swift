import Foundation

// MARK: - GPU Device Error Log (`crates/rune/src/gpu/health.rs`)

/// Action to take for an uncaptured GPU device error (`gpu::health::Note`).
public enum GpuErrorNote: Sendable, Equatable {
    /// The device's first error: log it with the adapter's description.
    case first
    /// An error not seen before: log it.
    case new
    /// The error that reached the limit: say that the rest won't be logged.
    case mute
    /// Seen before, or past the limit: log nothing.
    case quiet
}

/// Deduplicating GPU error log capping distinct messages at 4 (`gpu::health::ErrorLog`).
public struct GpuErrorLog: Sendable, Equatable {
    public static let differentLimit: Int = 4

    private var seen: [String] = []

    public init() {}

    public mutating func note(_ message: String) -> GpuErrorNote {
        if seen.count > Self.differentLimit || seen.contains(message) {
            return .quiet
        }
        seen.append(message)
        if seen.count == 1 {
            return .first
        }
        if seen.count > Self.differentLimit {
            return .mute
        }
        return .new
    }
}

// MARK: - GPU Backend Resolution & Adapter Pick Diagnostics (`crates/rune/src/gpu/backend.rs`, `pick.rs`)

/// Reason an adapter was selected (`gpu::pick::Reason`, `#1286`).
public enum GpuPickReason: Sendable, Equatable {
    case envName
    case envPower
    case compositor
    case display
    /// Offscreen or test work, on the GPU driving the primary display.
    case windowGpu
    case lowPower

    public var descriptionText: String {
        switch self {
        case .envName: return "WGPU_ADAPTER_NAME"
        case .envPower: return "WGPU_POWER_PREF"
        case .compositor: return "the compositor's GPU"
        case .display: return "the GPU driving the primary display"
        case .windowGpu: return "the GPU a window would get (it drives the primary display)"
        case .lowPower: return "lowest power"
        }
    }
}

/// Cross-platform adapter candidate description used by `GpuAdapterPicker` (`crates/rune-gpu/src/pick.rs`, `#1286`).
public struct GpuAdapterCandidate: Sendable, Equatable {
    public var name: String
    public var backend: String
    public var deviceType: String
    public var pciBusId: String
    public var isLowPower: Bool
    public var isHeadless: Bool
    public var isPrimaryDisplay: Bool
    public var isCompositor: Bool
    public var isSoftware: Bool
    public var supportsSurface: Bool

    public init(
        name: String,
        backend: String = "Metal",
        deviceType: String = "IntegratedGpu",
        pciBusId: String = "",
        isLowPower: Bool = true,
        isHeadless: Bool = false,
        isPrimaryDisplay: Bool = false,
        isCompositor: Bool = false,
        isSoftware: Bool = false,
        supportsSurface: Bool = true
    ) {
        self.name = name
        self.backend = backend
        self.deviceType = deviceType
        self.pciBusId = pciBusId
        self.isLowPower = isLowPower
        self.isHeadless = isHeadless
        self.isPrimaryDisplay = isPrimaryDisplay
        self.isCompositor = isCompositor
        self.isSoftware = isSoftware
        self.supportsSurface = supportsSurface
    }
}

/// Result of picking a GPU adapter (`crates/rune-gpu/src/pick.rs`).
public struct GpuPickOutcome: Sendable, Equatable {
    public var index: Int
    public var reason: GpuPickReason
    public var hardwareCount: Int
    public var compositor: String?

    public init(index: Int, reason: GpuPickReason, hardwareCount: Int, compositor: String? = nil) {
        self.index = index
        self.reason = reason
        self.hardwareCount = hardwareCount
        self.compositor = compositor
    }
}

/// Error returned when an explicit `WGPU_ADAPTER_NAME` or adapter pick finds no usable GPU (`#1286`).
public enum GpuPickError: Error, Sendable, Equatable, CustomStringConvertible {
    case noMatch(String)

    public var description: String {
        switch self {
        case let .noMatch(message):
            return message
        }
    }
}

/// Cross-platform GPU adapter selection & diagnostic logging policy matching `crates/rune-gpu/src/pick.rs` (`#1286`).
public enum GpuAdapterPicker {
    /// Whether `RUNE_GPU_LOG` asks to log every adapter pick in this process.
    public static func isGpuLogEnabled(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["RUNE_GPU_LOG"].map { $0 != "0" } ?? false
    }

    /// Formats one adapter pick line matching `pick::log`.
    public static func formatPick(
        name: String,
        backendLabel: String,
        backend: String,
        deviceType: String,
        pciBusId: String = "",
        reason: GpuPickReason,
        compositor: String? = nil
    ) -> String {
        let pci = pciBusId.isEmpty ? "" : ", \(pciBusId)"
        let comp = compositor.map { "; compositor on \($0)" } ?? ""
        return "rune: GPU \"\(name)\" (\(backendLabel); \(backend), \(deviceType)\(pci)): \(reason.descriptionText)\(comp)"
    }

    /// Formats a pick failure line matching `pick::log_failure`.
    public static func formatFailure(_ error: String) -> String {
        "rune: no GPU: \(error)"
    }

    /// Picks a GPU adapter following upstream `#1286`:
    /// 1. `WGPU_ADAPTER_NAME` (case-insensitive substring, including software adapters) — FINAL:
    ///    fails with an error rather than falling through to another GPU when no usable adapter matches.
    /// 2. `WGPU_POWER_PREF` (`high`, `low`, `none`).
    /// 3. Compositor GPU (`isCompositor`).
    /// 4. Primary display GPU (`isPrimaryDisplay`), for BOTH presented windows/overlays (`.display`)
    ///    and offscreen/test work (`.windowGpu`).
    /// 5. Lowest-power usable hardware GPU (`.lowPower`).
    public static func pick(
        candidates: [GpuAdapterCandidate],
        presented: Bool,
        compositor: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<GpuPickOutcome, GpuPickError> {
        let hardwareCount = candidates.filter { !$0.isSoftware }.count
        let isUsable: (GpuAdapterCandidate) -> Bool = { !presented || ($0.supportsSurface && !$0.isHeadless) }

        if let rawName = env["WGPU_ADAPTER_NAME"] {
            let needle = rawName.lowercased()
            let matching = candidates.enumerated().filter { _, c in
                needle.isEmpty || c.name.lowercased().contains(needle)
            }
            if let (idx, _) = matching.first(where: { isUsable($0.element) }) {
                return .success(GpuPickOutcome(
                    index: idx,
                    reason: .envName,
                    hardwareCount: candidates.count,
                    compositor: compositor
                ))
            }
            if matching.isEmpty {
                return .failure(.noMatch("no GPU adapter matches WGPU_ADAPTER_NAME=\"\(rawName)\""))
            }
            let tried = matching.map { "\"\($0.element.name)\" (can't present to this window)" }.joined(separator: ", ")
            return .failure(.noMatch("WGPU_ADAPTER_NAME=\"\(rawName)\" matched \(tried), none usable"))
        }

        if let pref = env["WGPU_POWER_PREF"]?.lowercased(), ["high", "low", "none"].contains(pref) {
            let picked: Int?
            switch pref {
            case "high":
                picked = candidates.indices.first(where: { isUsable(candidates[$0]) && !candidates[$0].isSoftware && !candidates[$0].isLowPower })
                    ?? candidates.indices.first(where: { isUsable(candidates[$0]) && !candidates[$0].isSoftware })
                    ?? candidates.indices.first(where: { isUsable(candidates[$0]) })
            case "low":
                picked = candidates.indices.first(where: { isUsable(candidates[$0]) && !candidates[$0].isSoftware && candidates[$0].isLowPower })
                    ?? candidates.indices.first(where: { isUsable(candidates[$0]) && !candidates[$0].isSoftware })
                    ?? candidates.indices.first(where: { isUsable(candidates[$0]) })
            default:
                picked = candidates.indices.first(where: { isUsable(candidates[$0]) && !candidates[$0].isSoftware })
                    ?? candidates.indices.first(where: { isUsable(candidates[$0]) })
            }
            if let picked {
                return .success(GpuPickOutcome(index: picked, reason: .envPower, hardwareCount: hardwareCount, compositor: compositor))
            }
            return .failure(.noMatch("no GPU adapter available for WGPU_POWER_PREF=\"\(pref)\""))
        }

        if let compIdx = candidates.indices.first(where: { isUsable(candidates[$0]) && candidates[$0].isCompositor }) {
            return .success(GpuPickOutcome(index: compIdx, reason: .compositor, hardwareCount: hardwareCount, compositor: compositor))
        }

        // Every device takes the GPU a window would get; `presented` only names the reason (`#1286`).
        if let dispIdx = candidates.indices.first(where: { isUsable(candidates[$0]) && !candidates[$0].isSoftware && candidates[$0].isPrimaryDisplay }) {
            let reason: GpuPickReason = presented ? .display : .windowGpu
            return .success(GpuPickOutcome(index: dispIdx, reason: reason, hardwareCount: hardwareCount, compositor: compositor))
        }

        if let lowIdx = candidates.indices.first(where: { isUsable(candidates[$0]) && !candidates[$0].isSoftware && candidates[$0].isLowPower })
            ?? candidates.indices.first(where: { isUsable(candidates[$0]) && !candidates[$0].isSoftware })
            ?? candidates.indices.first(where: { isUsable(candidates[$0]) }) {
            return .success(GpuPickOutcome(index: lowIdx, reason: .lowPower, hardwareCount: hardwareCount, compositor: compositor))
        }

        return .failure(.noMatch("no usable GPU adapter found"))
    }
}

/// Process-wide (and testable per-instance) adapter pick logger matching `pick::log` / `pick::log_failure` (`#1286`).
///
/// With `RUNE_GPU_LOG=1`, every adapter pick is logged; without it, multi-GPU machines (`adapters > 1`)
/// still log the first pick once per process. Pick failures are always logged.
public final class GpuPickLogger: @unchecked Sendable {
    public static let shared = GpuPickLogger()

    private let lock = NSLock()
    private var first = true

    public init() {}

    /// Returns true if a pick with `adapterCount` adapters should be printed under `env`.
    public func shouldLog(adapterCount: Int?, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if GpuAdapterPicker.isGpuLogEnabled(env: env) {
            return true
        }
        if let count = adapterCount, count > 1 {
            return lock.withLock {
                guard first else { return false }
                first = false
                return true
            }
        }
        return false
    }

    /// Logs a pick if `shouldLog` permits it, writing to `sink` (defaulting to stderr).
    @discardableResult
    public func logPick(
        name: String,
        backendLabel: String,
        backend: String,
        deviceType: String,
        pciBusId: String = "",
        reason: GpuPickReason,
        compositor: String? = nil,
        adapterCount: Int?,
        env: [String: String] = ProcessInfo.processInfo.environment,
        sink: ((String) -> Void)? = nil
    ) -> String? {
        guard shouldLog(adapterCount: adapterCount, env: env) else { return nil }
        let line = GpuAdapterPicker.formatPick(
            name: name,
            backendLabel: backendLabel,
            backend: backend,
            deviceType: deviceType,
            pciBusId: pciBusId,
            reason: reason,
            compositor: compositor
        )
        if let sink {
            sink(line)
        } else {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        return line
    }

    /// Always logs a failed pick (`rune: no GPU: ...`).
    @discardableResult
    public func logFailure(_ error: String, sink: ((String) -> Void)? = nil) -> String {
        let line = GpuAdapterPicker.formatFailure(error)
        if let sink {
            sink(line)
        } else {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        return line
    }
}

/// GPU backend selection for a Rune window.
public enum GpuBackendPolicy {
    #if canImport(Metal)
    public static let defaultBackend: GpuBackend = .metal
    #elseif os(Linux) || os(Windows) || os(Android) || os(WASI)
    public static let defaultBackend: GpuBackend = .gl
    #else
    public static let defaultBackend: GpuBackend = .software
    #endif

    /// Uses the environment override, then the app's choice, then the host default.
    public static func resolve(env: String?, chosen: GpuBackend?) -> GpuBackend {
        let backend = environmentBackend(env) ?? chosen ?? .auto
        return backend == .auto ? defaultBackend : backend
    }

    /// True when neither `RUNE_GPU_BACKEND` nor an explicit app preference selected the backend.
    public static func defaulted(env: String?, chosen: GpuBackend?) -> Bool {
        let requested = environmentBackend(env) ?? chosen
        return requested == nil || requested == .auto
    }

    private static func environmentBackend(_ value: String?) -> GpuBackend? {
        guard let value else { return nil }
        return value == "wgpu" ? .webGpu : GpuBackend(rawValue: value)
    }

    struct UnavailableBackend: Error, CustomStringConvertible {
        let requested: GpuBackend
        let available: GpuBackend
        var description: String {
            "Rune's window host uses \(available.rawValue). Requested backend \(requested.rawValue) is unavailable."
        }
    }

    static func windowBackend(_ chosen: GpuBackend = .auto) -> GpuBackend {
        resolve(env: ProcessInfo.processInfo.environment["RUNE_GPU_BACKEND"], chosen: chosen)
    }

    static func checkWindowBackend(_ chosen: GpuBackend = .auto) throws {
        let selected = windowBackend(chosen)
        #if canImport(UIKit) && !os(watchOS)
        if selected == .software { return }
        #endif
        guard selected == defaultBackend else {
            throw UnavailableBackend(requested: selected, available: defaultBackend)
        }
    }

    /// Human-readable GPU backend description matching `gpu::backend::describe`.
    public static func describe(deviceName: String, native: Bool, env: String? = nil, chosen: GpuBackend? = nil) -> String {
        let backendName = native ? "Rune's Metal backend" : "wgpu Metal"
        let why: String
        if native {
            if env == "metal" {
                why = "RUNE_GPU_BACKEND=metal"
            } else if chosen == .metal {
                why = "App::gpu_backend chose it"
            } else {
                why = "the default"
            }
        } else {
            if env == "wgpu" {
                why = "RUNE_GPU_BACKEND=wgpu"
            } else if chosen == .webGpu {
                why = "App::gpu_backend chose it"
            } else {
                why = "fallback"
            }
        }
        return "\(backendName) on \(deviceName) (\(why))"
    }
}
