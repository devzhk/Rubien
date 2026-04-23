// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Rubien",
    defaultLocalization: "en",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "RubienCore", targets: ["RubienCore"]),
        .library(name: "RubienSync", targets: ["RubienSync"]),
        .executable(name: "Rubien", targets: ["Rubien"]),
        .executable(name: "rubien-cli", targets: ["RubienCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "RubienCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .target(
            name: "RubienExceptionCatcher",
            path: "Sources/RubienExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RubienSync",
            dependencies: [
                "RubienCore",
                "RubienExceptionCatcher",
            ]
        ),
        .executableTarget(
            name: "Rubien",
            dependencies: [
                "RubienCore",
                "RubienSync",
                "RubienExceptionCatcher",
            ],
            exclude: [
                "Rubien.entitlements"
            ],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "RubienCLI",
            dependencies: [
                "RubienCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "RubienCoreTests",
            dependencies: ["RubienCore"],
            path: "Tests/RubienCoreTests"
        ),
        .testTarget(
            name: "RubienSyncTests",
            dependencies: ["RubienSync", "RubienCore", "RubienExceptionCatcher"],
            path: "Tests/RubienSyncTests"
        ),
        .testTarget(
            name: "RubienTests",
            dependencies: ["Rubien", "RubienCore", "RubienSync"],
            path: "Tests/RubienTests"
        ),
        .testTarget(
            name: "RubienCLITests",
            dependencies: [],
            path: "Tests/RubienCLITests"
        ),
    ]
)
