// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "background-activity",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackgroundActivity", targets: ["BackgroundActivity"]),
    ],
    targets: [
        .target(
            name: "BackgroundActivity",
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "BackgroundActivityTests",
            dependencies: ["BackgroundActivity"],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
    ],
)
