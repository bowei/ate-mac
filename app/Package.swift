// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AteMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AteMac", path: "Sources/AteMac"),
    ]
)
