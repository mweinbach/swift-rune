// swift-tools-version: 6.4
import PackageDescription

let package = Package(name: "WakeProbe", platforms: [.macOS(.v14)],
    products: [.executable(name: "wake-probe", targets: ["WakeProbe"])],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [.executableTarget(name: "WakeProbe", dependencies: [.product(name: "Rune", package: "swift-rune")],
        linkerSettings: [.unsafeFlags(["-Xlinker", "--export=rune_probe_late_image"], .when(platforms: [.wasi]))])])
