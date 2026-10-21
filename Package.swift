// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Darkslide",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Darkslide",
            path: "Sources/Darkslide",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        )
    ]
)
