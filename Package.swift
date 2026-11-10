// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NativeMonitor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NativeMonitor", targets: ["NativeMonitor"])],
    targets: [
        .target(name: "PrivateBackdrop", publicHeadersPath: "include"),
        .executableTarget(name: "NativeMonitor", dependencies: ["PrivateBackdrop"]),
        .testTarget(name: "NativeMonitorTests", dependencies: ["NativeMonitor"])
    ],
    swiftLanguageModes: [.v5]
)
