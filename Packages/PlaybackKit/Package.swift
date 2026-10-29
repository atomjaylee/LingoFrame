// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlaybackKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PlaybackKit", targets: ["PlaybackKit"])],
    dependencies: [
        .package(path: "../LearningCore"),
        .package(url: "https://github.com/kingslay/FFmpegKit.git", from: "9.0.2"),
    ],
    targets: [
        .target(name: "PlaybackKit", dependencies: [
            "LearningCore",
            .product(name: "libmpv", package: "FFmpegKit"),
        ]),
        .testTarget(name: "PlaybackKitTests", dependencies: ["PlaybackKit"]),
    ]
)
