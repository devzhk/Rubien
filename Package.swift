// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftLib",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftLibCore", targets: ["SwiftLibCore"]),
        .executable(name: "Slate", targets: ["SwiftLib"]),
        .executable(name: "slate-cli", targets: ["SwiftLibCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SwiftLibCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "SwiftLib",
            dependencies: [
                "SwiftLibCore",
            ],
            exclude: [
                "SwiftLib.entitlements"
            ],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "SwiftLibCLI",
            dependencies: [
                "SwiftLibCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SwiftLibCoreTests",
            dependencies: ["SwiftLibCore"],
            path: "Tests/SwiftLibCoreTests"
        ),
        .testTarget(
            name: "SwiftLibTests",
            dependencies: ["SwiftLib", "SwiftLibCore"],
            path: "Tests/SwiftLibTests"
        ),
        .testTarget(
            name: "SwiftLibCLITests",
            dependencies: [],
            path: "Tests/SwiftLibCLITests"
        ),
    ]
)
