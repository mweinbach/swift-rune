// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneSparseATKProbe",
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .executableTarget(
            name: "rune-sparse-atk-probe",
            dependencies: [.product(name: "Rune", package: "swift-rune")],
            path: ".",
            exclude: ["SparseUpdates.c", "ObserveParents.c", "External.py", "Demand.py"],
            sources: ["SparseTree.swift"]
        )
    ]
)
