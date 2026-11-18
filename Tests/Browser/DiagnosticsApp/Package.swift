// swift-tools-version: 6.4
import PackageDescription

let package = Package(name: "DiagnosticsProbe", platforms: [.macOS(.v14)],
    products: [.executable(name: "diagnostics-probe", targets: ["DiagnosticsProbe"])],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [.executableTarget(name: "DiagnosticsProbe",
        dependencies: ["Rune", "RuneKnobs", "RunePerf", "RuneMac"].map { .product(name: $0, package: "swift-rune") },
        linkerSettings: [.unsafeFlags(["-Xlinker", "--export=rune_probe_knob_sequence",
                                        "-Xlinker", "--export=rune_probe_frame_ms",
                                        "-Xlinker", "--export=rune_probe_diagnostics",
                                        "-Xlinker", "--export=rune_probe_strut"], .when(platforms: [.wasi]))])])
