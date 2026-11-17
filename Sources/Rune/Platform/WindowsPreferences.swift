#if os(Windows)
import CRuneWin32

enum WindowsPreferences {
    static func read(contrast override: SystemContrast? = nil) -> SystemPreferences {
        let native = rune_win_preferences()
        func color(_ rgb: UInt32) -> Color {
            Color.srgb(Float((rgb >> 16) & 255) / 255, Float((rgb >> 8) & 255) / 255,
                       Float(rgb & 255) / 255, 1)
        }
        let highContrast = native.high_contrast != 0 ? SystemContrast(
            window: color(native.window), text: color(native.text), highlight: color(native.highlight),
            highlightText: color(native.highlight_text), disabled: color(native.disabled),
            button: color(native.button), buttonText: color(native.button_text), link: color(native.link)
        ) : nil
        let accent = color(native.accent)
        return SystemPreferences(
            darkMode: native.dark < 0 ? nil : native.dark != 0, reducedMotion: native.reduced_motion != 0,
            contrast: override ?? highContrast, accent: SystemAccent(lightAccent: accent, darkAccent: accent),
            doubleClickInterval: Double(native.double_click_ms) / 1000,
            scrollBarStyle: native.overlay_scrollbars != 0 ? .overlay : .alwaysVisible
        )
    }

    static func scrollBars() -> SystemScrollBars {
        let overlay = rune_win_preferences().overlay_scrollbars != 0
        return SystemScrollBars(bars: overlay ? .whenScrolling : .always, scrollerOverlay: overlay)
    }
}
#endif
