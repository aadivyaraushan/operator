// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OperatorCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "OperatorCore", targets: ["OperatorCore"]),
    ],
    targets: [
        .target(name: "OperatorCore"),
        .testTarget(name: "OperatorCoreTests", dependencies: ["OperatorCore"]),
    ])
