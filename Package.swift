// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalAIKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "LocalAIKit",
            targets: ["LocalAIKit"]
        )
    ],
    targets: [
        .target(
            name: "LocalAIKit",
            path: "LocalAIKit"
        ),
        .testTarget(
            name: "LocalAIKitTests",
            dependencies: ["LocalAIKit"],
            path: "LocalAIKitTests"
        )
    ]
)
