// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalAIKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
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
        .binaryTarget(
            name: "llama",
            path: "build-apple/llama.xcframework"
        ),
        .target(
            name: "LocalAIKit",
            dependencies: ["llama"],
            path: "LocalAIKit"
        ),
        .testTarget(
            name: "LocalAIKitTests",
            dependencies: ["LocalAIKit"],
            path: "LocalAIKitTests"
        )
    ]
)
