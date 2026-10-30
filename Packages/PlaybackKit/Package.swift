// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlaybackKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PlaybackKit", targets: ["PlaybackKit"])],
    dependencies: [
        .package(path: "../LearningCore"),
        .package(path: "../PlaybackCore"),
        .package(url: "https://github.com/superuser404notfound/AetherEngine.git", exact: "7.52.0"),
    ],
    targets: [
        .target(name: "PlaybackNative", dependencies: [
            "LearningCore",
            "PlaybackCore",
            .product(name: "AetherEngine", package: "AetherEngine"),
        ], path: "Sources/PlaybackNative"),
        .target(name: "PlaybackKit", dependencies: ["PlaybackCore", "PlaybackNative"],
                path: "Sources/PlaybackKitFacade"),
        .testTarget(name: "PlaybackKitTests", dependencies: ["PlaybackKit"]),
    ]
)
