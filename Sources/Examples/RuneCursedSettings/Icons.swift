import Foundation
import Rune

enum CursedIcons {
    static let sun = SVGIcon(
        viewBox: 16.0,
        paths: [
            "M10.75 8 A2.75 2.75 0 1 1 5.25 8 A2.75 2.75 0 1 1 10.75 8",
            "M8 1.5V3M8 13V14.5M1.5 8H3M13 8H14.5M3.4 3.4L4.46 4.46M11.54 11.54L12.6 12.6M3.4 12.6L4.46 11.54M11.54 4.46L12.6 3.4",
        ],
        strokeWidth: 1.5
    )

    static let shield = SVGIcon(
        viewBox: 16.0,
        paths: [
            "M8 1.75L13 3.5V7.5C13 10.6 10.9 13.1 8 14.25C5.1 13.1 3 10.6 3 7.5V3.5L8 1.75Z",
        ],
        strokeWidth: 1.5
    )

    static let personCircle = SVGIcon(
        viewBox: 16.0,
        paths: [
            "M14.25 8 A6.25 6.25 0 1 1 1.75 8 A6.25 6.25 0 1 1 14.25 8",
            "M9 5.25 A1 1 0 1 1 7 5.25 A1 1 0 1 1 9 5.25",
            "M4.75 7H11.25M8 7V9.25M8 9.25L6.5 12M8 9.25L9.5 12",
        ],
        strokeWidth: 1.5
    )

    static let settingsGear = SVGIcon(
        viewBox: 16.0,
        paths: [
            "M10.25 8 A2.25 2.25 0 1 1 5.75 8 A2.25 2.25 0 1 1 10.25 8",
            "M8 1.5V3M8 13V14.5M1.5 8H3M13 8H14.5M3.4 3.4L4.6 4.6M11.4 11.4L12.6 12.6M3.4 12.6L4.6 11.4M11.4 4.6L12.6 3.4",
        ],
        strokeWidth: 1.4
    )

    static let globe = SVGIcon(
        viewBox: 16.0,
        paths: [
            "M14 8 A6 6 0 1 1 2 8 A6 6 0 1 1 14 8",
            "M2.3 8H13.7M8 2C9.8 4 9.8 12 8 14M8 2C6.2 4 6.2 12 8 14",
        ],
        strokeWidth: 1.4
    )

    static let console = SVGIcon(
        viewBox: 16.0,
        paths: [
            "M2.5 3.5H13.5V12.5H2.5Z",
            "M5 6.5L7 8L5 9.5M8 9.5H11",
        ],
        strokeWidth: 1.4
    )

    static let folder = SVGIcon(
        viewBox: 16.0,
        paths: [
            "M2 4.25C2 3.56 2.56 3 3.25 3H6.2L7.6 4.5H12.75C13.44 4.5 14 5.06 14 5.75V11.75C14 12.44 13.44 13 12.75 13H3.25C2.56 13 2 12.44 2 11.75V4.25Z",
        ],
        strokeWidth: 1.4
    )

    static let circleCheck = SVGIcon(
        viewBox: 16.0,
        paths: [
            "M14 8 A6 6 0 1 1 2 8 A6 6 0 1 1 14 8",
            "M5.5 8.2L7.2 9.9L10.7 6.3",
        ],
        strokeWidth: 1.5
    )
}
