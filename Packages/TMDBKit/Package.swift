// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TMDBKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "TMDBKit", targets: ["TMDBKit"])],
    targets: [
        .target(name: "TMDBKit"),
        .testTarget(name: "TMDBKitTests", dependencies: ["TMDBKit"]),
    ]
)
