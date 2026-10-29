// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LearningCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LearningCore", targets: ["LearningCore"]),
    ],
    targets: [
        .target(name: "LearningCore"),
        .testTarget(name: "LearningCoreTests", dependencies: ["LearningCore"]),
    ]
)
