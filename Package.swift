// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TangentBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TangentBar", path: "Sources/TangentBar")
    ]
)
