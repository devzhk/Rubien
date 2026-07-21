# Building Rubien

This guide covers local macOS development, tests, app bundles, troubleshooting, and the repository layout. For Linux CLI installation and builds, see [Linux CLI](Linux-CLI.md).

## Requirements

- macOS 14.4 (Sonoma) or later
- Apple Silicon
- Xcode 16.3 or later with the Swift 6 toolchain

`swift test` requires the full Xcode toolchain, not only Command Line Tools. Check the active toolchain with:

```bash
xcode-select -p
```

## Development loop

Run the app directly from the current checkout or worktree:

```bash
swift run Rubien
```

Run the Mac CLI:

```bash
swift run rubien-cli list
```

Run all tests or a focused test:

```bash
swift test
swift test --filter CitationFormatterTests
swift test --filter RubienCoreTests.CitationFormatterTests/testAPA
```

For ordinary UI checks from a worktree, use `swift run Rubien`. Avoid launching by application name, which may bring an installed copy of Rubien to the foreground instead of the worktree build.

## App bundles and DMGs

```bash
./scripts/build-app.sh
./scripts/build-app.sh release
```

Build outputs land in `build/` as `Rubien.app` and `Rubien-{Debug,Release}.dmg`.

Use `./scripts/dev-launch.sh` only when you need signed-app behavior such as App Group or CloudKit entitlements. Before preparing or publishing a release, follow [the release runbook](Release-Runbook.md).

## Troubleshooting stale SwiftPM checkouts

After switching the active developer toolchain between Command Line Tools and Xcode, SwiftPM's checkout cache can become inconsistent. Typical errors include:

```text
'grdb.swift': Source files for target CSQLite should be located under 'Sources/CSQLite'
'swift-argument-parser': invalid custom path 'Tools/generate-docc-reference'
```

Remove the generated SwiftPM state and resolve dependencies again:

```bash
rm -rf .build .swiftpm
swift package resolve
swift run Rubien
```

This removes build products and dependency checkouts, not the Rubien library database. See [Data storage and backups](Data-Storage.md) for library locations.

## Project layout

```text
Sources/
├── Rubien/                # SwiftUI app, readers, and Assistant; Mac only
├── RubienCore/            # Models, database, metadata, import, and citation logic
├── RubienPDFKit/          # Cross-platform PDF facade and platform backends
├── RubienSync/            # CloudKit mapping and CKSyncEngine; Mac only
├── RubienCLI/             # Cross-platform rubien-cli executable
├── RubienBrowserHost/     # Chrome native-messaging bridge
├── CPoppler/              # Linux poppler-glib and cairo system-library shim
└── CGdkPixbuf/            # Linux gdk-pixbuf system-library shim
Tests/
├── RubienCoreTests/
├── RubienSyncTests/
├── RubienTests/
├── RubienCLITests/
├── RubienBrowserHostTests/
└── RubienPDFKitTests/
scripts/
├── build-app.sh           # Build the app bundle and DMG
├── dev-launch.sh          # Launch a signed development app
├── note-editor/           # TipTap/ProseMirror note-editor assets
└── release.sh             # Signed release pipeline
mcp-server/                # Node.js MCP server package
BrowserExtension/          # Chrome extension
```

The Swift package's target definitions and platform-conditional dependencies live in [`Package.swift`](../Package.swift).
