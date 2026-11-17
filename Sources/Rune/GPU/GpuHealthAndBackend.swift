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
