// swift-tools-version: 5.9
import PackageDescription

// Mac-only products (`Rubien` SwiftUI app + `RubienSync` CloudKit library)
// are gated out of the manifest on non-Darwin. The targets themselves stay
// declared (so `Sources/Rubien` and `Sources/RubienSync` aren't orphan
// source directories), but with nothing in the Linux build graph reaching
// them — no product, no test-target dep — SwiftPM skips compiling them.
// This is cleaner than per-source-file `#if os(macOS)` gates: the dep
// graph itself does the exclusion.
var products: [Product] = [
    .library(name: "RubienCore", targets: ["RubienCore"]),
    .executable(name: "rubien-cli", targets: ["RubienCLI"]),
]
#if os(macOS)
products.append(.library(name: "RubienSync", targets: ["RubienSync"]))
products.append(.executable(name: "Rubien", targets: ["Rubien"]))
#endif

let package = Package(
    name: "Rubien",
    defaultLocalization: "en",
    platforms: [.macOS("14.4")],
    products: products,
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "RubienCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
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
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: [
                "RubienCLI.entitlements"
            ]
        ),
        .testTarget(
            name: "RubienCoreTests",
            dependencies: ["RubienCore"],
            path: "Tests/RubienCoreTests"
        ),
        .testTarget(
            name: "RubienSyncTests",
            dependencies: [
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
                "RubienCore",
                .target(name: "RubienExceptionCatcher", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/RubienSyncTests"
        ),
        .testTarget(
            name: "RubienTests",
            dependencies: [
                .target(name: "Rubien", condition: .when(platforms: [.macOS])),
                "RubienCore",
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/RubienTests"
        ),
        .testTarget(
            name: "RubienCLITests",
            dependencies: [
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/RubienCLITests"
        ),
    ]
)
