// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCap",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "MacCap", targets: ["MacCap"])],
    targets: [
        .executableTarget(name: "MacCap"),
        .testTarget(name: "MacCapTests", dependencies: ["MacCap"])
    ]
)
