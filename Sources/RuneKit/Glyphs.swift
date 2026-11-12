import Foundation
import Rune

/// Additional built-in vector glyphs matching `rune_kit::glyphs`.
extension KitIcons {
    public static let mic = SVGIcon(
        viewBox: 16,
        paths: [
            "M5.5 4A2.5 2.5 0 0 1 10.5 4V7A2.5 2.5 0 0 1 5.5 7Z",
            "M3.5 7V7.5A4.5 4.5 0 0 0 12.5 7.5V7",
            "M8 12V14.5",
            "M5.5 14.5H10.5",
        ],
        strokeWidth: 1.4
    )

    public static let keyboard = SVGIcon(
        viewBox: 16,
        paths: [
            "M1.5 3.5H14.5V12.5H1.5Z",
            "M4.5 6.5H5.5",
            "M7.5 6.5H8.5",
            "M10.5 6.5H11.5",
            "M5.5 9.5H10.5",
        ],
        strokeWidth: 1.4
    )

    public static let cursorText = SVGIcon(
        viewBox: 16,
        paths: [
            "M5.5 2.5H10.5",
            "M8 2.5V13.5",
            "M5.5 13.5H10.5",
        ],
        strokeWidth: 1.4
    )

    public static let sparkle = SVGIcon(
        viewBox: 16,
        paths: [
            "M8 1.5Q10 6 14.5 8Q10 10 8 14.5Q6 10 1.5 8Q6 6 8 1.5Z",
        ],
        strokeWidth: 1.4
    )

    public static let star = SVGIcon(
        viewBox: 16,
        paths: [
            "M8 2.1L9.7 6.25L14.18 6.59L10.76 9.5L11.82 13.86L8 11.5L4.18 13.86L5.24 9.5L1.82 6.59L6.3 6.25Z",
        ],
        strokeWidth: 1.4
    )

    public static let starFilled = SVGIcon(
        viewBox: 16,
        paths: [
            "M8 2.1L9.7 6.25L14.18 6.59L10.76 9.5L11.82 13.86L8 11.5L4.18 13.86L5.24 9.5L1.82 6.59L6.3 6.25Z",
        ],
        strokeWidth: 1.8
    )

    public static let folderOpen = SVGIcon(
        viewBox: 16,
        paths: [
            "M1.5 13.5V3.5H6L7.5 5H13.5V7.5",
            "M1.5 13.5L3.5 7.5H15L13 13.5H1.5Z",
        ],
        strokeWidth: 1.4
    )

    public static let fileCode = SVGIcon(
        viewBox: 16,
        paths: [
            "M3.5 1.5H9.5L12.5 4.5V14.5H3.5V1.5Z",
            "M9.5 1.5V4.5H12.5",
            "M7 8L5.5 9.75L7 11.5",
            "M9 8L10.5 9.75L9 11.5",
        ],
        strokeWidth: 1.4
    )

    public static let fileText = SVGIcon(
        viewBox: 16,
        paths: [
            "M3.5 1.5H9.5L12.5 4.5V14.5H3.5V1.5Z",
            "M9.5 1.5V4.5H12.5",
            "M5.5 8.5H10.5",
            "M5.5 10.5H10.5",
            "M5.5 12.5H8.5",
        ],
        strokeWidth: 1.4
    )

    public static let fileImage = SVGIcon(
        viewBox: 16,
        paths: [
            "M3.5 1.5H9.5L12.5 4.5V14.5H3.5V1.5Z",
            "M9.5 1.5V4.5H12.5",
            "M3.5 12.5L6.5 9.5L8 11L9.5 9.5L12.5 12.5",
        ],
        strokeWidth: 1.4
    )
}
