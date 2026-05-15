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
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CPoppler",
            path: "Sources/CPoppler",
            pkgConfig: "poppler-glib",
            providers: [.apt(["libpoppler-glib-dev", "libcairo2-dev"])]
        ),
        .systemLibrary(
            name: "CGdkPixbuf",
            path: "Sources/CGdkPixbuf",
            pkgConfig: "gdk-pixbuf-2.0",
            providers: [.apt(["libgdk-pixbuf-2.0-dev"])]
        ),
        .target(
            name: "RubienPDFKit",
            dependencies: [
                .target(name: "CPoppler", condition: .when(platforms: [.linux])),
                .target(name: "CGdkPixbuf", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/RubienPDFKit"
        ),
        .target(
            name: "RubienCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                "RubienPDFKit",
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
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
                .target(name: "RubienExceptionCatcher", condition: .when(platforms: [.macOS])),
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
            name: "RubienPDFKitTests",
            dependencies: ["RubienPDFKit"],
            path: "Tests/RubienPDFKitTests",
            resources: [
                .copy("Fixtures")
            ]
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
