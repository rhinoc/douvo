// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Douvo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Douvo", targets: ["Douvo"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "Douvo",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Douvo",
            exclude: [
                "Info.plist"
            ],
            resources: [
                .process("Resources/MenuBarIcon.svg"),
                .copy("Resources/mlx-swift_Cmlx.bundle")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Douvo/Info.plist"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "DouvoTests",
            dependencies: ["Douvo"],
            path: "Tests/DouvoTests"
        )
    ]
)
