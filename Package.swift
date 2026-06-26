// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Douvo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Douvo", targets: ["Douvo"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "Douvo",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Douvo",
            exclude: [
                "Info.plist"
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Douvo/Info.plist"
                ], .when(platforms: [.macOS]))
            ]
        )
    ]
)
