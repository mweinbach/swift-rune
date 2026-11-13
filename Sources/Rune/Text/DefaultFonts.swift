import Foundation
#if canImport(CoreText)
import CoreText
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
        #else
        return false
        #endif
    }()

    /// Registers the bundled `.ttf` fonts with CoreText for the current process once.
    @discardableResult
    public static func registerIfNeeded() -> Bool {
        registrationResult
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

private extension URL {
    func takeIfExists() -> URL? {
        FileManager.default.fileExists(atPath: path) ? self : nil
    }
}
