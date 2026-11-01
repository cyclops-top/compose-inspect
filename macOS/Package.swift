// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComposeInspect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ComposeInspectLauncher", targets: ["ComposeInspectApp"]),
        .library(name: "ComposeInspectCore", targets: ["ComposeInspectCore"]),
    ],
    targets: [
        .target(name: "ComposeInspectCore"),
        .executableTarget(name: "ComposeInspectApp", dependencies: ["ComposeInspectCore"]),
        .testTarget(name: "ComposeInspectCoreTests", dependencies: ["ComposeInspectCore"]),
        .testTarget(name: "ComposeInspectAppTests", dependencies: ["ComposeInspectApp"]),
    ]
)
