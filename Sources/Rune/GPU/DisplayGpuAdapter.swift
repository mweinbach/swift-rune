import Foundation

/// Identifies the graphics driver backing a live rendering context.
public struct DisplayGpuAdapter: Equatable, Sendable, CustomStringConvertible {
    public enum Backend: String, Sendable {
        case metal = "Metal"
        case openGL = "OpenGL"
        case openGLES = "OpenGL ES"
        case webGL2 = "WebGL 2"
    }

    public let backend: Backend
    public let device: String
    public let vendor: String?
    public let version: String?

    public init(backend: Backend, device: String, vendor: String? = nil, version: String? = nil) {
        self.backend = backend
        self.device = device
        self.vendor = vendor
        self.version = version
    }

    public var description: String {
        [backend.rawValue, vendor, device, version].compactMap { $0 }.joined(separator: " | ")
    }

    /// Opt-in startup diagnostics, including software GL implementations' own driver names.
    public func reportIfRequested() {
        if ProcessInfo.processInfo.environment["RUNE_GPU_INFO"] == "1" {
            FileHandle.standardError.write(Data("Rune GPU: \(description)\n".utf8))
        }
    }
}
