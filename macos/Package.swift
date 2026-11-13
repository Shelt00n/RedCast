// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RedCast",
    platforms: [.macOS(.v14)],
    dependencies: [
        // WhisperKit (Argmax): on-device Whisper on CoreML / Apple Neural Engine
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "RedCast",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/RedCast"
        ),
    ]
)
