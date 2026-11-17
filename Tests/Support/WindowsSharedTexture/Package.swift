// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "WindowsSharedTexture",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "SwiftRune", path: "../../..")],
    targets: [
        .executableTarget(
            name: "SharedTextureConsumer",
            dependencies: [
                .product(name: "Rune", package: "SwiftRune"),
                .product(name: "RuneRef", package: "SwiftRune"),
                .product(name: "RuneMotion", package: "SwiftRune")
            ],
            path: "Consumer"
        ),
        .executableTarget(
            name: "SharedTextureProducer",
            path: "Producer",
            linkerSettings: [
                .linkedLibrary("swiftCore", .when(platforms: [.windows])),
                .linkedLibrary("d3d11", .when(platforms: [.windows])),
                .linkedLibrary("d3d12", .when(platforms: [.windows])),
                .linkedLibrary("dxgi", .when(platforms: [.windows]))
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
