// swift-tools-version: 6.0
// Package.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026
import PackageDescription

let package = Package(
    name: "Prism",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Prism", targets: ["Prism"]),
        .executable(name: "prism-bench", targets: ["PrismBench"]),
        .executable(name: "PrismStudio", targets: ["PrismStudio"]),
    ],
    targets: [
        .target(
            name: "Prism",
            resources: [.process("Shaders")]
        ),
        .executableTarget(name: "PrismBench", dependencies: ["Prism"], path: "Benchmarks", exclude: ["results"]),
        .executableTarget(
            name: "PrismStudio",
            dependencies: ["Prism"],
            path: "Examples/PrismStudio",
            exclude: ["README.md"]
        ),
        .testTarget(name: "PrismTests", dependencies: ["Prism"]),
    ],
    swiftLanguageModes: [.v6]
)
