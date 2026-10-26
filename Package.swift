// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NPVCore",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [.library(name: "NPVCore", targets: ["NPVCore"])],
    targets: [
        .target(name: "NPVCore", path: "Sources/Core"),
        .testTarget(name: "NPVCoreTests", dependencies: ["NPVCore"], path: "Tests/CoreTests")
    ]
)
