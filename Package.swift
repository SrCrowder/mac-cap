// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCap",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "MacCap", targets: ["MacCap"])],
    dependencies: [
        // Automatic updates. Keep in sync with SPARKLE_VERSION in .github/workflows/build.yml.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "MacCap",
            dependencies: [.product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MacCapTests", dependencies: ["MacCap"])
    ]
)
