// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PortWeaver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PortWeaverCore", targets: ["PortWeaverCore"]),
        .executable(name: "PortWeaver", targets: ["PortWeaver"]),
    ],
    targets: [
        .target(name: "PortWeaverCore"),
        .executableTarget(name: "PortWeaver", dependencies: ["PortWeaverCore"]),
        .testTarget(name: "PortWeaverCoreTests", dependencies: ["PortWeaverCore"]),
    ]
)
