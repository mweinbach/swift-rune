// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneOverlayProbe",
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [.executableTarget(name: "OverlayProbe", dependencies: [.product(name: "Rune", package: "swift-rune")],
                                path: ".", exclude: ["probe.c"], sources: ["main.swift"])]
)
