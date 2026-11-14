import Foundation
#if os(macOS)
import CoreFoundation
#endif

/// The user's `AppleFontSmoothing` preference (`text/macos.rs::smoothing_allowed_by_user`,
/// `text/coretext_match.rs::smoothing_allowed_by_user`, upstream `#954`).
///
/// Retina-like text follows `AppleFontSmoothing` 0 on macOS, as AppKit, SwiftUI and GPUI do:
/// `FontSmoothing.on` then draws as `.off` (the `ApplePipeline.unsmoothed` pipeline). The value
/// is read once per process, from this app's domain or the global one
/// (`CFPreferencesCopyAppValue(…, kCFPreferencesCurrentApplication)`); a string counts as its
/// number, as `NSUserDefaults` reads one. Off macOS smoothing stays allowed.
public enum AppleFontSmoothingPreference {
    /// The integer level a preference value holds: a number as is, a string parsed (trimmed) as an
    /// integer, anything else `nil` (`value.downcast::<CFNumber>()` / `CFString` → `parse::<i64>`).
    /// A `CFBoolean` (`defaults write … -bool false`) is neither a `CFNumber` nor a `CFString`, so
    /// it reads as `nil` and smoothing stays on, as upstream's downcasts fail for it.
    public static func level(from value: Any?) -> Int64? {
        guard let value else { return nil }
        #if canImport(Darwin)
        let cf = value as CFTypeRef
        let type = CFGetTypeID(cf)
        if type == CFNumberGetTypeID() {
            return (cf as! NSNumber).int64Value
        }
        if type == CFStringGetTypeID() {
            return Int64((cf as! String).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
        #else
        if let string = value as? String {
            return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let number = value as? NSNumber, !(value is Bool) {
            return number.int64Value
        }
        return nil
        #endif
    }

    /// Whether a preference value lets text smooth: false only when it reads 0 (`level != Some(0)`).
    public static func allows(value: Any?) -> Bool {
        level(from: value) != 0
    }

    /// `AppleFontSmoothing` read once (`OnceLock`); true off macOS.
    public static let smoothingAllowedByUser: Bool = {
        #if os(macOS)
        let key = "AppleFontSmoothing" as CFString
        guard let value = CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication) else {
            return true
        }
        return allows(value: value)
        #else
        return true
        #endif
    }()
}

extension FontSmoothing {
    /// `FontSmoothing::pipeline` with the user's preference given: `.on` draws as `.off` when the
    /// user turned smoothing off (`AppleFontSmoothing` 0); otherwise every stage for smoothed modes
    /// and all but the dilation for the rest.
    public func pipeline(smoothingAllowedByUser allowed: Bool) -> ApplePipeline {
        let resolved = (self == .systemDefault) ? Self.classic : self
        if resolved == .on && !allowed {
            return .unsmoothed
        }
        return isEnabled ? .smoothed : .unsmoothed
    }
}
