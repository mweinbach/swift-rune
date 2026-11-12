import Foundation
import Rune

/// Additional built-in vector glyphs matching `rune_kit::glyphs`.
extension KitIcons {
    public static let mic = SVGIcon(
        viewBox: 16,
        paths: [
            "M5.5 4A2.5 2.5 0 0 1 10.5 4V7A2.5 2.5 0 0 1 5.5 7Z",
            "M3.5 7V7.5A4.5 4.5 0 0 0 12.5 7.5V7M8 12V14.5M5.5 14.5H10.5",
        ],
        strokeWidth: 1.0
    )

    public static let keyboard = SVGIcon(
        viewBox: 16,
        paths: [
            "M3 3.5H13A1.5 1.5 0 0 1 14.5 5V11A1.5 1.5 0 0 1 13 12.5H3A1.5 1.5 0 0 1 1.5 11V5A1.5 1.5 0 0 1 3 3.5Z",
            "M4.5 6.5H5.5M7.5 6.5H8.5M10.5 6.5H11.5M5.5 9.5H10.5",
        ],
        strokeWidth: 1.0
    )

    public static let cursorText = SVGIcon(
        viewBox: 16,
        paths: [
            "M5.5 2.5H10.5M8 2.5V13.5M5.5 13.5H10.5",
        ],
        strokeWidth: 1.0
    )

    public static let sparkle = SVGIcon(
        viewBox: 16,
        paths: [
            "M8 1.5Q10 6 14.5 8Q10 10 8 14.5Q6 10 1.5 8Q6 6 8 1.5Z",
        ],
        strokeWidth: 1.0
    )

    public static let star = SVGIcon(
        viewBox: 16,
        paths: [
            "M8 2.1L9.7 6.25L14.18 6.59L10.76 9.5L11.82 13.86L8 11.5L4.18 13.86L5.24 9.5L1.82 6.59L6.3 6.25Z",
        ],
        strokeWidth: 1.0
    )

    public static let starFilled = SVGIcon(
        viewBox: 16,
        paths: [
            "M8 2.1L9.7 6.25L14.18 6.59L10.76 9.5L11.82 13.86L8 11.5L4.18 13.86L5.24 9.5L1.82 6.59L6.3 6.25Z",
        ],
        strokeWidth: nil
    )

    public static let folderOpen = SVGIcon(
        viewBox: 16,
        paths: [
            "M1.5 13.5V3.5H6L7.5 5H13.5V7.5",
            "M1.5 13.5L3.5 7.5H15L13 13.5H1.5Z",
        ],
        strokeWidth: 1.0
    )

    public static let fileCode = SVGIcon(
        viewBox: 16,
        paths: [
            "M3.5 1.5H9.5L12.5 4.5V14.5H3.5V1.5Z",
            "M9.5 1.5V4.5H12.5",
            "M7 8L5.5 9.75L7 11.5M9 8L10.5 9.75L9 11.5",
        ],
        strokeWidth: 1.0
    )

    public static let fileText = SVGIcon(
        viewBox: 16,
        paths: [
            "M3.5 1.5H9.5L12.5 4.5V14.5H3.5V1.5Z",
            "M9.5 1.5V4.5H12.5",
            "M5.5 8.5H10.5M5.5 10.5H10.5M5.5 12.5H8.5",
        ],
        strokeWidth: 1.0
    )

    public static let fileImage = SVGIcon(
        viewBox: 16,
        paths: [
            "M3.5 1.5H9.5L12.5 4.5V14.5H3.5V1.5Z",
            "M9.5 1.5V4.5H12.5",
            "M6 7.5A0.5 0.5 0 1 0 7 7.5A0.5 0.5 0 1 0 6 7.5Z",
            "M3.5 12.5L6.5 9.5L8 11L9.5 9.5L12.5 12.5",
        ],
        strokeWidth: 1.0
    )

    /// All 28 built-in glyphs matching `rune_kit::glyphs` (`tests/glyphs.rs`).
    public static let allBuiltIn: [SVGIcon] = [
        check, checkSmall, chevronDown, chevronUp, caretRight, triangleDown, triangleRight,
        close, copy, search, circleX, lock, eye, eyeOff, dash, folder, folderOpen,
        file, fileCode, fileText, fileImage, mic, keyboard, cursorText, arrowRight,
        sparkle, star, starFilled,
    ]
}
