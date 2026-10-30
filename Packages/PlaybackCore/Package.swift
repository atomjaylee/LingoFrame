// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlaybackCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PlaybackCore", targets: ["PlaybackCore"])],
    targets: [
        .target(name: "PlaybackCore"),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"]),
    ]
)
