import Foundation
#if canImport(CoreText)
import CoreText
#elseif canImport(CRuneDesktopText)
import CRuneDesktopText
import RuneRef
#endif

/// Bundled fallback font faces (`Inter` and `IBM Plex Mono`) matching upstream
/// `crates/rune/src/text/default_fonts.rs`.
///
/// `FontFamiliesRegistry` defaults to empty overrides (`""`) so `TextSystem.setFamilies(sans: "", mono: "")`
/// remains a no-op; `TextSystem.resolveCTFont` falls back to these bundled families whenever no
/// override or matching installed family is active.
public enum DefaultFonts {
    public static let sansFamily = "Inter"
    public static let monoFamily = "IBM Plex Mono"

    /// Asset filenames (without `.ttf`) bundled under `Resources/Fonts`.
    public static let bundledFontNames: [String] = [
        "Inter-Regular",
        "Inter-Medium",
        "Inter-SemiBold",
        "IBMPlexMono-Regular",
    ]

    private static let registrationResult: Bool = {
        #if canImport(CoreText)
        var allOK = true
        for name in bundledFontNames {
            guard let url = fontURL(named: name) else {
                allOK = false
                continue
            }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !ok {
                if let cfError = error?.takeRetainedValue(),
                   CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
                    continue
                }
                allOK = false
            }
        }
        return allOK
        #elseif os(WASI)
        // Browser FontFace assets are loaded before the reactor mounts. A standalone
        // WASI process may have no filesystem or resource bundle.
        return false
        #elseif canImport(CRuneDesktopText)
        var allOK = true
        for name in bundledFontNames {
            guard let url = fontURL(named: name),
                  rune_desktop_register_font_file(url.path) != 0 else {
                allOK = false
                continue
            }
        }
        return allOK
        #else
        return false
        #endif
    }()

    /// Registers the bundled faces with the native text backend for this process.
    @discardableResult
    public static func registerIfNeeded() -> Bool {
        #if os(Android) && canImport(CRuneDesktopText)
        // NativeActivity registers APK assets before constructing the Runtime.
        return rune_android_bundled_fonts_ready() != 0
        #else
        return registrationResult
        #endif
    }

    public static var resourceBundle: Bundle { Bundle.module }

    public static func fontURL(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.module.resourceURL?.appendingPathComponent("Fonts/\(name).ttf")
            .takeIfExists()
            ?? Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Resources/Fonts")
            ?? Bundle.module.url(forResource: name, withExtension: "ttf")
    }
}

#if canImport(CRuneDesktopText) && !canImport(CoreText)
/// Application font bytes stay available to layouts for the lifetime of the process.
internal final class DesktopAppFonts: @unchecked Sendable {
    static let shared = DesktopAppFonts()
    private let lock = NSLock()
    private var registered: Set<[UInt8]> = []

    func register(_ fonts: [Data]) {
        guard !fonts.isEmpty else { return }
        DefaultFonts.registerIfNeeded()
        var changed = false
        for font in fonts {
            guard !font.isEmpty, let length = UInt32(exactly: font.count) else { continue }
            let digest = Blake3.hash(Array(font))
            lock.lock()
            if !registered.contains(digest) {
                let ok = font.withUnsafeBytes {
                    rune_desktop_register_font_bytes($0.bindMemory(to: UInt8.self).baseAddress, length) != 0
                }
                if ok {
                    registered.insert(digest)
                    changed = true
                }
            }
            lock.unlock()
        }
        if changed { FontFamiliesRegistry.bumpEpoch() }
    }
}
#endif

private extension URL {
    func takeIfExists() -> URL? {
        FileManager.default.fileExists(atPath: path) ? self : nil
    }
}
