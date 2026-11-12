// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swift-rune",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "RuneMotion", targets: ["RuneMotion"]),
        .library(name: "RuneRef", targets: ["RuneRef"]),
        .library(name: "RuneI18n", targets: ["RuneI18n"]),
        .library(name: "Rune", targets: ["Rune"]),
        .library(name: "RuneKit", targets: ["RuneKit"]),
        .library(name: "RuneNotify", targets: ["RuneNotify"]),
        .library(name: "RuneMac", targets: ["RuneMac"]),
        .library(name: "RunePerf", targets: ["RunePerf"]),
        .library(name: "RuneHighlights", targets: ["RuneHighlights"]),
        .library(name: "RuneFX", targets: ["RuneFX"]),
        .library(name: "RuneLight", targets: ["RuneLight"]),
        .library(name: "RuneKnobs", targets: ["RuneKnobs"]),
        .library(name: "RuneMermaid", targets: ["RuneMermaid"]),
        .library(name: "OpenCodeTheme", targets: ["OpenCodeTheme"]),
        .library(name: "RuneTaffy", targets: ["RuneTaffy"]),
        .library(name: "RuneLuau", targets: ["RuneLuau"]),
        .library(name: "RuneRegister", targets: ["RuneRegister"]),
        .executable(name: "rune-hello", targets: ["RuneHello"]),
        .executable(name: "rune-todo", targets: ["RuneTodo"]),
        .executable(name: "rune-settings", targets: ["RuneSettings"]),
        .executable(name: "rune-ref", targets: ["RuneRefCLI"]),
        .executable(name: "rune-parity", targets: ["RuneParityCLI"]),
        .executable(name: "rune-shapes", targets: ["RuneShapes"]),
        .executable(name: "rune-glass-card", targets: ["RuneGlassCard"]),
        .executable(name: "rune-launcher", targets: ["RuneLauncher"]),
        .executable(name: "rune-playground", targets: ["RunePlayground"]),
        .executable(name: "rune-kit-gallery", targets: ["RuneKitGallery"]),
        .executable(name: "rune-motion-bento", targets: ["RuneMotionBento"]),
        .executable(name: "rune-background", targets: ["RuneBackground"]),
        .executable(name: "rune-cursed-settings", targets: ["RuneCursedSettings"]),
        .executable(name: "rune-drag-out", targets: ["RuneDragOut"]),
        .executable(name: "rune-drop-files", targets: ["RuneDropFiles"]),
        .executable(name: "rune-frosted-bar", targets: ["RuneFrostedBar"]),
        .executable(name: "rune-glass-panel", targets: ["RuneGlassPanel"]),
        .executable(name: "rune-knobs", targets: ["RuneKnobsDemo"]),
        .executable(name: "rune-lab", targets: ["RuneLab"]),
        .executable(name: "rune-live-values", targets: ["RuneLiveValues"]),
        .executable(name: "rune-luau-panel", targets: ["RuneLuauPanel"]),
        .executable(name: "rune-matched", targets: ["RuneMatched"]),
        .executable(name: "rune-odometer", targets: ["RuneOdometer"]),
        .executable(name: "rune-overlay", targets: ["RuneOverlay"]),
        .executable(name: "rune-overlay-lab", targets: ["RuneOverlayLab"]),
        .executable(name: "rune-rich-clipboard", targets: ["RuneRichClipboard"]),
        .executable(name: "rune-showreel", targets: ["RuneShowreel"]),
        .executable(name: "rune-site-scenes", targets: ["RuneSiteScenes"]),
        .executable(name: "rune-sketch", targets: ["RuneSketch"]),
        .executable(name: "rune-video-player", targets: ["RuneVideoPlayer"]),
        .executable(name: "rune-video-tiles", targets: ["RuneVideoTiles"]),
        .executable(name: "rune-web-hello", targets: ["RuneWebHello"]),
        .executable(name: "rune-web-showcase", targets: ["RuneWebShowcase"]),
    ],
    targets: [
        .target(
            name: "RuneMotion",
            path: "Sources/RuneMotion"
        ),
        .target(
            name: "RuneRef",
            path: "Sources/RuneRef"
        ),
        .target(
            name: "RuneI18n",
            path: "Sources/RuneI18n"
        ),
        .target(
            name: "Rune",
            dependencies: [
                "RuneMotion",
                "RuneRef",
            ],
            path: "Sources/Rune",
            linkerSettings: [
                .linkedLibrary("user32", .when(platforms: [.windows])),
                .linkedLibrary("gdi32", .when(platforms: [.windows])),
                .linkedLibrary("dwmapi", .when(platforms: [.windows])),
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
                .linkedLibrary("android", .when(platforms: [.android])),
                .linkedLibrary("log", .when(platforms: [.android])),
            ]
        ),
        .target(
            name: "RuneKit",
            dependencies: [
                "Rune",
                "RuneI18n",
                "RuneHighlights",
                "RuneMermaid",
            ],
            path: "Sources/RuneKit"
        ),
        .target(
            name: "RuneNotify",
            path: "Sources/RuneNotify"
        ),
        .target(
            name: "RuneMac",
            dependencies: ["RuneNotify"],
            path: "Sources/RuneMac"
        ),
        .target(
            name: "RunePerf",
            path: "Sources/RunePerf",
            linkerSettings: [
                .linkedLibrary("psapi", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "RuneHighlights",
            path: "Sources/RuneHighlights"
        ),
        .target(
            name: "RuneFX",
            dependencies: ["RuneMotion", "Rune"],
            path: "Sources/RuneFX"
        ),
        .target(
            name: "RuneLight",
            dependencies: ["Rune"],
            path: "Sources/RuneLight"
        ),
        .target(
            name: "RuneKnobs",
            dependencies: ["Rune"],
            path: "Sources/RuneKnobs"
        ),
        .target(
            name: "RuneMermaid",
            dependencies: ["Rune"],
            path: "Sources/RuneMermaid"
        ),
        .target(
            name: "OpenCodeTheme",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/OpenCodeTheme"
        ),
        .target(
            name: "RuneTaffy",
            path: "Sources/RuneTaffy"
        ),
        .target(
            name: "RuneLuau",
            dependencies: ["Rune"],
            path: "Sources/RuneLuau"
        ),
        .target(
            name: "RuneRegister",
            path: "Sources/RuneRegister"
        ),
        .executableTarget(
            name: "RuneHello",
            dependencies: ["Rune"],
            path: "Sources/Examples/RuneHello"
        ),
        .executableTarget(
            name: "RuneTodo",
            dependencies: ["Rune"],
            path: "Sources/Examples/RuneTodo"
        ),
        .executableTarget(
            name: "RuneSettings",
            dependencies: ["Rune", "RuneKit", "RuneMotion"],
            path: "Sources/Examples/RuneSettings"
        ),
        .executableTarget(
            name: "RuneRefCLI",
            dependencies: ["RuneRef", "Rune"],
            path: "Sources/Examples/RuneRefCLI"
        ),
        .executableTarget(
            name: "RuneParityCLI",
            dependencies: ["RuneRef", "Rune"],
            path: "Sources/Examples/RuneParityCLI"
        ),
        .executableTarget(
            name: "RuneShapes",
            dependencies: ["Rune"],
            path: "Sources/Examples/RuneShapes"
        ),
        .executableTarget(
            name: "RuneGlassCard",
            dependencies: ["Rune"],
            path: "Sources/Examples/RuneGlassCard"
        ),
        .executableTarget(
            name: "RuneLauncher",
            dependencies: ["Rune"],
            path: "Sources/Examples/RuneLauncher"
        ),
        .executableTarget(
            name: "RunePlayground",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RunePlayground"
        ),
        .executableTarget(
            name: "RuneKitGallery",
            dependencies: ["Rune", "RuneKit", "OpenCodeTheme"],
            path: "Sources/Examples/RuneKitGallery"
        ),
        .executableTarget(
            name: "RuneMotionBento",
            dependencies: ["Rune", "RuneMotion", "RuneKit"],
            path: "Sources/Examples/RuneMotionBento"
        ),
        .executableTarget(
            name: "RuneBackground",
            dependencies: ["Rune", "RuneFX", "RuneLight"],
            path: "Sources/Examples/RuneBackground"
        ),
        .executableTarget(
            name: "RuneCursedSettings",
            dependencies: ["Rune", "RuneMotion", "RuneKit", "OpenCodeTheme", "RuneFX", "RuneLight"],
            path: "Sources/Examples/RuneCursedSettings"
        ),
        .executableTarget(
            name: "RuneDragOut",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneDragOut"
        ),
        .executableTarget(
            name: "RuneDropFiles",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneDropFiles"
        ),
        .executableTarget(
            name: "RuneFrostedBar",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneFrostedBar"
        ),
        .executableTarget(
            name: "RuneGlassPanel",
            dependencies: ["Rune", "RuneLight", "RuneKit"],
            path: "Sources/Examples/RuneGlassPanel"
        ),
        .executableTarget(
            name: "RuneKnobsDemo",
            dependencies: ["Rune", "RuneKnobs", "RuneKit"],
            path: "Sources/Examples/RuneKnobsDemo"
        ),
        .executableTarget(
            name: "RuneLab",
            dependencies: ["Rune", "RuneMotion", "RuneKit", "RuneFX", "RuneLight"],
            path: "Sources/Examples/RuneLab"
        ),
        .executableTarget(
            name: "RuneLiveValues",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneLiveValues"
        ),
        .executableTarget(
            name: "RuneLuauPanel",
            dependencies: ["Rune", "RuneLuau", "RuneKit"],
            path: "Sources/Examples/RuneLuauPanel"
        ),
        .executableTarget(
            name: "RuneMatched",
            dependencies: ["Rune", "RuneMotion", "RuneKit"],
            path: "Sources/Examples/RuneMatched"
        ),
        .executableTarget(
            name: "RuneOdometer",
            dependencies: ["Rune", "RuneMotion", "RuneKit"],
            path: "Sources/Examples/RuneOdometer"
        ),
        .executableTarget(
            name: "RuneOverlay",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneOverlay"
        ),
        .executableTarget(
            name: "RuneOverlayLab",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneOverlayLab"
        ),
        .executableTarget(
            name: "RuneRichClipboard",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneRichClipboard"
        ),
        .executableTarget(
            name: "RuneShowreel",
            dependencies: ["Rune", "RuneMotion", "RuneKit", "RuneFX", "RuneLight", "RuneMermaid"],
            path: "Sources/Examples/RuneShowreel"
        ),
        .executableTarget(
            name: "RuneSiteScenes",
            dependencies: ["Rune", "RuneFX", "RuneLight", "RuneRef"],
            path: "Sources/Examples/RuneSiteScenes"
        ),
        .executableTarget(
            name: "RuneSketch",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneSketch"
        ),
        .executableTarget(
            name: "RuneVideoPlayer",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneVideoPlayer"
        ),
        .executableTarget(
            name: "RuneVideoTiles",
            dependencies: ["Rune", "RuneKit"],
            path: "Sources/Examples/RuneVideoTiles"
        ),
        .executableTarget(
            name: "RuneWebHello",
            dependencies: ["Rune"],
            path: "Sources/Examples/RuneWebHello"
        ),
        .executableTarget(
            name: "RuneWebShowcase",
            dependencies: ["Rune", "RuneKit", "RuneMotion"],
            path: "Sources/Examples/RuneWebShowcase"
        ),
        .testTarget(
            name: "RuneMotionTests",
            dependencies: ["RuneMotion"],
            path: "Tests/RuneMotionTests"
        ),
        .testTarget(
            name: "RuneRefTests",
            dependencies: ["RuneRef", "Rune"],
            path: "Tests/RuneRefTests"
        ),
        .testTarget(
            name: "RuneI18nTests",
            dependencies: ["RuneI18n"],
            path: "Tests/RuneI18nTests"
        ),
        .testTarget(
            name: "RuneTests",
            dependencies: ["Rune", "RuneMotion", "RuneRef"],
            path: "Tests/RuneTests"
        ),
        .testTarget(
            name: "RuneKitTests",
            dependencies: ["RuneKit", "Rune", "RuneI18n", "RuneRef", "RuneHighlights", "RuneMermaid"],
            path: "Tests/RuneKitTests"
        ),
        .testTarget(
            name: "RuneNotifyTests",
            dependencies: ["RuneNotify"],
            path: "Tests/RuneNotifyTests"
        ),
        .testTarget(
            name: "RuneMacTests",
            dependencies: ["RuneMac", "RuneNotify"],
            path: "Tests/RuneMacTests"
        ),
        .testTarget(
            name: "RunePerfTests",
            dependencies: ["RunePerf"],
            path: "Tests/RunePerfTests"
        ),
        .testTarget(
            name: "RuneHighlightsTests",
            dependencies: ["RuneHighlights"],
            path: "Tests/RuneHighlightsTests"
        ),
        .testTarget(
            name: "RuneFXTests",
            dependencies: ["RuneFX", "RuneMotion", "Rune"],
            path: "Tests/RuneFXTests"
        ),
        .testTarget(
            name: "RuneLightTests",
            dependencies: ["RuneLight", "Rune"],
            path: "Tests/RuneLightTests"
        ),
        .testTarget(
            name: "RuneKnobsTests",
            dependencies: ["RuneKnobs", "Rune"],
            path: "Tests/RuneKnobsTests"
        ),
        .testTarget(
            name: "RuneMermaidTests",
            dependencies: ["RuneMermaid", "Rune"],
            path: "Tests/RuneMermaidTests"
        ),
        .testTarget(
            name: "OpenCodeThemeTests",
            dependencies: ["OpenCodeTheme", "Rune", "RuneKit"],
            path: "Tests/OpenCodeThemeTests"
        ),
        .testTarget(
            name: "RuneTaffyTests",
            dependencies: ["RuneTaffy"],
            path: "Tests/RuneTaffyTests"
        ),
        .testTarget(
            name: "RuneLuauTests",
            dependencies: ["RuneLuau", "Rune"],
            path: "Tests/RuneLuauTests"
        ),
        .testTarget(
            name: "RuneRegisterTests",
            dependencies: ["RuneRegister"],
            path: "Tests/RuneRegisterTests"
        ),
        .testTarget(
            name: "RuneParityTests",
            dependencies: ["RuneParityCLI", "RuneRef", "Rune"],
            path: "Tests/RuneParityTests"
        ),
        .testTarget(
            name: "RuneExamplesTests",
            dependencies: [
                "Rune",
                "RuneKit",
                "RuneKnobs",
                "RuneMotion",
                "RuneRef",
                "RuneHello",
                "RuneTodo",
                "RuneSettings",
                "RuneFrostedBar",
                "RuneMatched",
                "RuneKnobsDemo",
                "RuneLab",
            ],
            path: "Tests/RuneExamplesTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
