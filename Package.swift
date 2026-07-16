// swift-tools-version: 6.1
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
    traits: [
        .default(enabledTraits: ["Sparkle"]),
        .init(
            name: "Sparkle",
            description: "Enable Sparkle auto-updater (DMG distribution). Disable for Mac App Store builds via --disable-default-traits."
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
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
            name: "RubienCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "RubienPDFKit",
            dependencies: [
                "RubienCore",
                .target(name: "CPoppler", condition: .when(platforms: [.linux])),
                .target(name: "CGdkPixbuf", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/RubienPDFKit"
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
                "RubienPDFKit",
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
                .target(name: "RubienExceptionCatcher", condition: .when(platforms: [.macOS])),
                // The portable Assistant subset (ClaudeSessionStore, CodexAppServerProtocol,
                // AssistantAttachments, …) compiles on Linux; its SHA-256 needs swift-crypto
                // there, mirroring RubienCore/RubienCLI.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(
                    name: "Sparkle",
                    package: "Sparkle",
                    condition: .when(platforms: [.macOS], traits: ["Sparkle"])
                ),
            ],
            exclude: [
                "Rubien.entitlements"
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .define("Sparkle", .when(platforms: [.macOS], traits: ["Sparkle"])),
            ]
        ),
        .executableTarget(
            name: "RubienCLI",
            dependencies: [
                "RubienCore",
                "RubienPDFKit",
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            exclude: [
                "RubienCLI.entitlements"
            ]
        ),
        .testTarget(
            name: "RubienCoreTests",
            dependencies: [
                "RubienCore",
                // Mac-only — the PDF-touching test files in this target are
                // file-level `#if canImport(PDFKit)`-gated, so Linux skips
                // them. Keeping the RubienPDFKit dep off the Linux dep graph
                // is load-bearing: linking poppler into the RubienCoreTests
                // bundle on Linux triggers an XCTest+GCD hang between test
                // methods. See Docs/Linux-PDF-Backend.md.
                .target(name: "RubienPDFKit", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/RubienCoreTests",
            resources: [
                .copy("Fixtures/CitationMeta")
            ]
        ),
        .testTarget(
            name: "RubienPDFKitTests",
            dependencies: [
                // Mac-only target. SPM bundles all test targets into one
                // `RubienPackageTests.xctest` whose link graph is the union
                // of every test target's deps; linking poppler into that
                // bundle on Linux causes XCTest+libdispatch to hang between
                // test methods (see Docs/Linux-PDF-Backend.md). Keeping the
                // dep Mac-only keeps libpoppler off the Linux umbrella
                // bundle. Linux parity verification: build green + a
                // `rubien-cli pdf info` smoke test (Phase 3 step 6).
                .target(name: "RubienPDFKit", condition: .when(platforms: [.macOS])),
            ],
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
                .target(name: "RubienPDFKit", condition: .when(platforms: [.macOS])),
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/RubienTests"
        ),
        .testTarget(
            name: "RubienCLITests",
            dependencies: [
                .target(name: "RubienSync", condition: .when(platforms: [.macOS])),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/RubienCLITests"
        ),
    ],
    // Tools-version 6.1 unlocks package traits (used below for Sparkle),
    // but we keep the Swift language mode at 5 so the existing codebase
    // doesn't have to absorb a strict-concurrency migration as part of
    // the auto-updater work.
    swiftLanguageModes: [.v5]
)
