// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Exitpilot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Exitpilot", path: "Sources/Exitpilot")
    ]
)
