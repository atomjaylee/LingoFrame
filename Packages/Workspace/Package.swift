// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Workspace",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Workspace", targets: ["Workspace"])],
    dependencies: [.package(path: "../DesignSystem")],
    targets: [
        .target(name: "Workspace", dependencies: ["DesignSystem"]),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace"]),
    ]
)
