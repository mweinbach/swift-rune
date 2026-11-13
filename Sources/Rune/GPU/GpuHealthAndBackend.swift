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

/// Reason an adapter was selected (`gpu::pick::Reason`).
public enum GpuPickReason: Sendable, Equatable {
    case envName
    case envPower
    case compositor
    case display
    case lowPower

    public var descriptionText: String {
        switch self {
        case .envName: return "WGPU_ADAPTER_NAME"
        case .envPower: return "WGPU_POWER_PREF"
        case .compositor: return "the compositor's GPU"
        case .display: return "the GPU driving the primary display"
        case .lowPower: return "lowest power"
        }
    }
}

/// Apple native-Metal vs wgpu selection parity helpers (`gpu::backend`).
public enum GpuBackendPolicy {
    #if os(macOS)
    public static let defaultBackend: GpuBackend = .metal
    #else
    public static let defaultBackend: GpuBackend = .metal
    #endif

    /// Resolves effective backend from `RUNE_GPU_BACKEND` (`"metal"` / `"wgpu"`) over app choice over default.
    public static func resolve(env: String?, chosen: GpuBackend?) -> GpuBackend {
        switch env {
        case "metal":
            return .metal
        case "wgpu":
            return .webGpu
        default:
            return chosen ?? defaultBackend
        }
    }

    /// True when neither `RUNE_GPU_BACKEND` nor an explicit app preference selected the backend.
    public static func defaulted(env: String?, chosen: GpuBackend?) -> Bool {
        let explicitEnv = (env == "metal" || env == "wgpu")
        return !explicitEnv && chosen == nil
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
