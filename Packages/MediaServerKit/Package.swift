// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MediaServerKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MediaServerKit", targets: ["MediaServerKit"])],
    targets: [
        .target(name: "MediaServerKit"),
        .testTarget(name: "MediaServerKitTests", dependencies: ["MediaServerKit"]),
    ]
)
