# Mac auto-updater — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v0.1.0 (Alpha) as a signed, notarized DMG with Sparkle 2 auto-updater. Future releases roll out automatically with a Claude-Desktop-style silent-background-download + click-to-relaunch UX, while user-initiated checks fall through to Sparkle's standard interactive UI.

**Architecture:** Sparkle 2.7+ as SPM dependency on the `Rubien` app target only, gated by a `Sparkle` package trait (default-enabled, so DMG builds get it and a future MAS flavor opts out via `--disable-default-traits`). Three SwiftUI surfaces — toolbar badge, app-menu item, Settings → Updates pane — driven by an `@Observable UpdateController` that wraps `SPUStandardUpdaterController` and suppresses Sparkle's default UI for scheduled checks via a custom `SPUStandardUserDriverDelegate`. Release pipeline rewrite: `VERSION` + `BUILD` files drive `Info.plist` stamping; `scripts/lib/codesign.sh` signs the five Sparkle components in strict order without `--deep` (with `--preserve-metadata=entitlements` on `Downloader.xpc`); `scripts/release.sh` orchestrates build → notarize → staple → EdDSA-sign → append to `docs/appcast.xml` → `gh release create`. Appcast on GitHub Pages, binaries on GitHub Releases.

**Tech Stack:** Swift 6.1+ (Package Traits), SwiftUI, Observation framework, Sparkle 2.7+, Apple Developer ID + notarytool, GitHub Releases + GitHub Pages, XCTest.

**Spec:** `Docs/superpowers/specs/2026-05-16-mac-auto-updater-design.md`. Refer to it for design rationale on every choice below.

---

## File Structure

**Create:**

- `VERSION` — single-line marketing version (`0.1.0`)
- `BUILD` — single-line monotonic build counter (`1`), incremented per release
- `Sources/Rubien/Services/Updates/UpdateConstants.swift` — feed URL, intervals, public-key constant (read at compile time via `#if Sparkle`)
- `Sources/Rubien/Services/Updates/UpdaterProtocol.swift` — protocol abstraction over `SPUUpdater` for unit testability
- `Sources/Rubien/Services/Updates/UpdateUserDriverDelegate.swift` — `SPUStandardUserDriverDelegate` impl that suppresses scheduled-check UI and forwards "update ready" via a callback
- `Sources/Rubien/Services/Updates/UpdateController.swift` — `@MainActor @Observable` wrapper around `SPUStandardUpdaterController`; strongly retains the delegate; exposes `updateReadyToInstall`, `pendingVersion`, toggles, `checkNow()`, `installAndRelaunch()`
- `Sources/Rubien/Views/Updates/UpdateIndicator.swift` — toolbar badge view
- `Sources/Rubien/Views/Updates/UpdateSettingsView.swift` — Settings → General → Updates pane
- `Sources/Rubien/Views/Updates/UpdateMenuCommands.swift` — `Commands` block adding "Restart to Install Update" to the Rubien menu
- `Tests/RubienTests/UpdateControllerTests.swift` — state-machine tests using a mock updater
- `Tests/RubienTests/UpdateUserDriverDelegateTests.swift` — delegate callback tests
- `scripts/release.sh` — release orchestrator
- `scripts/lib/appcast.sh` — appcast `<item>` block renderer
- `docs/appcast.xml` — RSS skeleton, populated per release
- `docs/staging-appcast.xml` — parallel appcast for end-to-end staging tests
- `docs/index.md` — GitHub Pages landing page
- `Docs/Release-Runbook.md` — one-time setup, per-release procedure, recovery scenarios

**Modify:**

- `Package.swift` — bump `swift-tools-version: 5.9` → `6.1`; add `traits:` array; add Sparkle package dependency; add conditional product dep + `swiftSettings` define to `Rubien` target
- `Sources/Rubien/RubienApp.swift` — instantiate `UpdateController` (inside `#if Sparkle`), inject into SwiftUI environment, add `UpdateMenuCommands()` to the App's `Commands` block
- `Sources/Rubien/Views/RubienSettingsView.swift` — add Updates section to the settings tree, gated by `#if Sparkle`
- `Sources/Rubien/Views/ContentView.swift` — add `UpdateIndicator()` to the main library window's toolbar trailing items, gated by `#if Sparkle`
- `Sources/Rubien/Rubien.entitlements` — add `com.apple.security.temporary-exception.mach-lookup.global-name` array with `-spks` and `-spki` strings
- `scripts/build-app.sh` — read `VERSION` and `BUILD`, stamp `Info.plist` via `plutil`; gain flavor arg (`dmg` default, `mas` errors); inject Sparkle Info.plist keys when flavor=dmg
- `scripts/lib/codesign.sh` — rewrite signing to the ordered five-step Sparkle recipe; switch from `--timestamp=none` to `--timestamp` (notarization requires Apple-timestamped signatures)
- `CLAUDE.md` — add "Releases" section pointing at `Docs/Release-Runbook.md` and documenting the trait-based MAS gating

---

## Prerequisites (manual, done once before Task 1)

These are not code tasks; they're one-time operator setup. Confirm complete before starting Phase 1.

- [ ] **P1: Apple Developer ID Application certificate.** Xcode → Settings → Accounts → Manage Certificates → + → "Developer ID Application". Export the resulting cert as `.p12` (right-click → Export); store in 1Password Personal vault. Verify identity is visible via `security find-identity -v -p codesigning | grep "Developer ID Application"`.

- [ ] **P2: Generate EdDSA keypair for Sparkle.** This requires Sparkle's `generate_keys` tool, which is built once we add the Sparkle SPM dependency (Task 7). Defer to **Task 8** in the plan flow.

- [ ] **P3: Create notarytool keychain profile.** Generate an app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords. Then:
  ```bash
  xcrun notarytool store-credentials "RubienNotary" \
      --apple-id "you@example.com" \
      --team-id "9TXK4V3SS8" \
      --password "<app-specific-password>"
  ```
  Verify: `xcrun notarytool history --keychain-profile RubienNotary` returns without auth errors (empty history is fine).

- [ ] **P4: Enable GitHub Pages.** GitHub.com → repo `devzhk/Rubien` → Settings → Pages → Source: "Deploy from a branch" → Branch: `main` → Folder: `/docs`. Save. Verify within ~60s that `https://devzhk.github.io/Rubien/` returns 200 (will be 404 until `docs/index.md` lands in Task 28).

---

## Phase 1 — Package.swift migration to Swift 6.1 + Sparkle trait

### Task 1: Bump swift-tools-version 5.9 → 6.1

**Files:**
- Modify: `Package.swift:1`

- [ ] **Step 1: Edit the tools-version header**

Change line 1 of `Package.swift`:
```swift
// swift-tools-version: 6.1
```

- [ ] **Step 2: Verify clean build**

```bash
rm -rf .build .swiftpm
swift package resolve
swift build
```
Expected: builds cleanly. If "checkouts" errors appear, that's the documented stale-cache foot-gun (`CLAUDE.md`); the `rm -rf` above already handles it.

- [ ] **Step 3: Verify full test suite still passes**

```bash
swift test
```
Expected: all existing tests pass. If new warnings appear under 6.1 (deprecation of 5.x patterns), do NOT fix them here — that's scope creep. File mentally; press on.

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "Bump swift-tools-version to 6.1 for Package Traits support

Prerequisite for the Sparkle auto-updater work (next commits). The 6.x
toolchain has been the build host requirement since Swift 6.0; this
manifest bump unlocks the traits API."
```

### Task 2: Add Sparkle SPM dependency with trait gating

**Files:**
- Modify: `Package.swift` — add `traits:` array, Sparkle dependency, conditional product dep + `swiftSettings` define on `Rubien` target

- [ ] **Step 1: Add the `traits:` array**

Insert between the `platforms:` line and the `products:` line in `Package.swift`:

```swift
    defaultLocalization: "en",
    platforms: [.macOS("15.0")],
    traits: [
        .default(enabledTraits: ["Sparkle"]),
        .init(
            name: "Sparkle",
            description: "Enable Sparkle auto-updater (DMG distribution). Disable for Mac App Store builds via --disable-default-traits."
        ),
    ],
```

- [ ] **Step 2: Add Sparkle to the dependencies list**

Add to the `dependencies:` array:

```swift
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
```

- [ ] **Step 3: Add conditional product dependency to the Rubien target**

In the `Rubien` executable target's `dependencies:` array, add at the end (after the existing macOS-conditional deps):

```swift
                .product(
                    name: "Sparkle",
                    package: "Sparkle",
                    condition: .when(traits: ["Sparkle"])
                ),
```

- [ ] **Step 4: Add the `swiftSettings:` clause**

The `Rubien` target currently has no `swiftSettings:` argument. Add it as the last argument (after `resources:`):

```swift
            resources: [
                .process("Assets.xcassets"),
                .process("Resources")
            ],
            swiftSettings: [
                .define("Sparkle", .when(traits: ["Sparkle"])),
            ]
```

- [ ] **Step 5: Verify the package resolves and links Sparkle**

```bash
swift package resolve
swift build 2>&1 | grep -i sparkle
```
Expected: Sparkle 2.7.x appears in the resolved checkout list; `swift build` succeeds. The build shouldn't fail just because no Swift source `#imports Sparkle` yet — SPM is fine with declared-but-unused product dependencies.

- [ ] **Step 6: Smoke-test trait disablement**

```bash
swift build --disable-default-traits 2>&1 | grep -i sparkle || echo "OK: Sparkle absent from build graph"
```
Expected: no Sparkle in the build output. (The grep prints nothing; the `|| echo` fires the success message.)

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "Add Sparkle 2.7 SPM dependency gated by Sparkle package trait

DMG builds get Sparkle by default; --disable-default-traits removes
the framework from the link graph for future MAS builds. The trait
also defines a 'Sparkle' compilation condition for #if-gated code."
```

---

## Phase 2 — Version + build infrastructure

### Task 3: Create VERSION and BUILD files

**Files:**
- Create: `VERSION`, `BUILD`

- [ ] **Step 1: Create VERSION file**

```bash
echo "0.1.0" > VERSION
```

- [ ] **Step 2: Create BUILD file**

```bash
echo "1" > BUILD
```

- [ ] **Step 3: Verify files**

```bash
cat VERSION BUILD
```
Expected:
```
0.1.0
1
```

- [ ] **Step 4: Commit**

```bash
git add VERSION BUILD
git commit -m "Add VERSION and BUILD source-of-truth files

VERSION: SemVer marketing version (CFBundleShortVersionString).
BUILD: monotonic integer (CFBundleVersion) Sparkle compares for
'is this newer'. Both stamped into Info.plist at build time by
scripts/build-app.sh."
```

### Task 4: Refactor build-app.sh to read VERSION/BUILD and stamp Info.plist

**Files:**
- Modify: `scripts/build-app.sh`

- [ ] **Step 1: Read the current build-app.sh top portion**

```bash
head -60 scripts/build-app.sh
```
Note the existing variable declarations and helper-source pattern.

- [ ] **Step 2: Add VERSION/BUILD reading after the BUNDLE_ID line**

In `scripts/build-app.sh`, immediately after the `BUNDLE_ID="${BUNDLE_ID:-com.rubien.app}"` line and before any function definitions, add:

```bash
VERSION="$(cat "$PROJECT_DIR/VERSION" | tr -d '[:space:]')"
BUILD_NUMBER="$(cat "$PROJECT_DIR/BUILD" | tr -d '[:space:]')"

if [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
    echo "✗ VERSION or BUILD file missing or empty" >&2
    exit 1
fi

echo "▸ Building Rubien $VERSION (build $BUILD_NUMBER)"
```

- [ ] **Step 3: Modify `write_info_plist` to use the variables**

Locate the heredoc that writes `Info.plist` (it currently hardcodes `<string>1.0.0</string>` and `<string>1</string>`). Replace those two specific values:

```bash
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
```

- [ ] **Step 4: Restructure `assemble_app_bundle` so version stamping runs for both paths**

The current `assemble_app_bundle` has an early `return` in the xcodebuild path, then a fallback heredoc path. We need post-build stamping to run regardless of which path created the bundle (Task 19 will add Sparkle key stamping with the same structure). Restructure with `if/else`:

```bash
assemble_app_bundle() {
    echo "▸ Assembling $APP_NAME.app..."
    rm -rf "$APP_BUNDLE"
    mkdir -p "$OUTPUT_DIR"

    if [ -d "$PRODUCTS_DIR/$APP_NAME.app" ]; then
        cp -R "$PRODUCTS_DIR/$APP_NAME.app" "$APP_BUNDLE"
        update_info_plist_bundle_id
    else
        mkdir -p "$APP_BUNDLE/Contents/MacOS"
        mkdir -p "$APP_BUNDLE/Contents/Resources"
        cp "$PRODUCTS_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

        for bundle in "$PRODUCTS_DIR"/*.bundle; do
            [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        done

        write_info_plist
    fi

    stamp_info_plist_version
}
```

Then define the new function alongside `write_info_plist`:

```bash
stamp_info_plist_version() {
    local plist="$APP_BUNDLE/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    /usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
    echo "   ✓ Stamped Info.plist: $VERSION ($BUILD_NUMBER)"
}
```

Replacing the early `return` with `if/else` is the load-bearing change — without it, Task 19's Sparkle-key stamping would only run on the xcodebuild path and the heredoc fallback would silently produce an unsigned/unstamped bundle.

- [ ] **Step 5: Test on a debug build**

```bash
./scripts/build-app.sh debug
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Rubien.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" build/Rubien.app/Contents/Info.plist
```
Expected:
```
0.1.0
1
```

- [ ] **Step 6: Commit**

```bash
git add scripts/build-app.sh
git commit -m "build-app.sh: stamp Info.plist from VERSION + BUILD files

Removes hardcoded 1.0.0/1 in the inline plist heredoc; adds a
post-build plutil stamp step that handles both the heredoc path
and the xcodebuild-produced plist path."
```

### Task 5: Add `dmg` / `mas` flavor argument to build-app.sh

**Files:**
- Modify: `scripts/build-app.sh`

- [ ] **Step 1: Replace the MODE parsing with flavor + config parsing**

The current `build-app.sh` accepts `debug` or `release` as `$1`. Extend to accept an optional second arg `dmg` or `mas` (default `dmg`). Replace the existing MODE block at the top:

```bash
MODE="${1:-debug}"
FLAVOR="${2:-dmg}"

if [ "$MODE" = "release" ]; then
    CONFIGURATION="Release"
else
    CONFIGURATION="Debug"
fi

case "$FLAVOR" in
    dmg)
        : # default; nothing extra
        ;;
    mas)
        echo "✗ MAS flavor not yet implemented (reserved for future App Store builds)" >&2
        echo "  When implemented: --disable-default-traits + Mac App Distribution cert + Transporter upload." >&2
        exit 64
        ;;
    *)
        echo "✗ Unknown flavor '$FLAVOR'. Expected 'dmg' or 'mas'." >&2
        exit 64
        ;;
esac
```

- [ ] **Step 2: Verify backward compatibility**

```bash
./scripts/build-app.sh debug   # should work as before
./scripts/build-app.sh release # should work as before
```
Expected: both produce a Rubien.app under `build/`. Output now also says `Building Rubien 0.1.0 (build 1)`.

- [ ] **Step 3: Verify MAS flavor errors cleanly**

```bash
./scripts/build-app.sh release mas
```
Expected: exits with code 64 and a clear "not yet implemented" message.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-app.sh
git commit -m "build-app.sh: add flavor argument (dmg default, mas reserved)

Reserves the MAS path for a future App Store build flavor; for v1 it
exits 64 with a message. Default behavior unchanged for dmg flavor
callers."
```

---

## Phase 3 — Entitlements

### Task 6: Add Sparkle mach-lookup keys to Rubien.entitlements

**Files:**
- Modify: `Sources/Rubien/Rubien.entitlements`

- [ ] **Step 1: Read the current entitlements file**

```bash
cat Sources/Rubien/Rubien.entitlements
```
Note structure — it's a plist with a top-level `<dict>` containing keys like `com.apple.security.app-sandbox`, `com.apple.security.network.client`, etc.

- [ ] **Step 2: Add the mach-lookup temporary-exception entries**

Inside the top-level `<dict>` of `Sources/Rubien/Rubien.entitlements`. Plist key order is not semantically meaningful, but for diff readability insert near the other `com.apple.security.*` keys (e.g., after `com.apple.security.network.client`):

```xml
	<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
	<array>
		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
	</array>
```

The `$(PRODUCT_BUNDLE_IDENTIFIER)` variable is resolved by codesign at signing time. Don't hardcode `com.rubien.app`; the variable form is portable across flavors.

- [ ] **Step 3: Verify plist is valid**

```bash
/usr/bin/plutil -lint Sources/Rubien/Rubien.entitlements
```
Expected: `Sources/Rubien/Rubien.entitlements: OK`.

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien/Rubien.entitlements
git commit -m "Add Sparkle XPC mach-lookup temporary-exception entitlements

Required for the sandboxed app to communicate with Sparkle's
InstallerLauncher (-spks) and Installer (-spki) XPC services.
Future MAS entitlements file will NOT include these — App Review
flags them and the MAS build doesn't bundle Sparkle anyway."
```

---

## Phase 4 — Sparkle integration code (TDD where applicable)

### Task 7: Create UpdateConstants.swift

**Files:**
- Create: `Sources/Rubien/Services/Updates/UpdateConstants.swift`

- [ ] **Step 1: Create the file**

```swift
#if Sparkle
import Foundation

enum UpdateConstants {
    /// GitHub Pages-served appcast for production releases.
    static let productionFeedURL = URL(string: "https://devzhk.github.io/Rubien/appcast.xml")!

    /// Sibling appcast for end-to-end staging tests; activated by the
    /// STAGING_FEED=1 environment variable or the equivalent Info.plist
    /// override in debug builds.
    static let stagingFeedURL = URL(string: "https://devzhk.github.io/Rubien/staging-appcast.xml")!

    /// Background check cadence; matches the SUScheduledCheckInterval
    /// stamped into Info.plist at build time.
    static let scheduledCheckInterval: TimeInterval = 86_400
}
#endif
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build 2>&1 | tail -20
```
Expected: builds cleanly. (If `#if Sparkle` is failing to enable, the trait wiring in Task 2 has an issue — go back and check.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Services/Updates/UpdateConstants.swift
git commit -m "Sparkle: add UpdateConstants for feed URLs and check interval"
```

### Task 8: Generate EdDSA keypair (manual step), record public key

**Files:**
- This is a manual operator step; no source files yet. Public key is recorded in a temp location and used in Task 22.

- [ ] **Step 1: Locate Sparkle's `generate_keys` tool**

```bash
find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f 2>/dev/null | head -3
# OR: find .build -name "generate_keys" -type f
find .build -name "generate_keys" -type f 2>/dev/null
```
The tool ships in the Sparkle SPM artifact bundle. If neither find succeeds, run a Sparkle-using swift build first; the artifact will materialize under `.build/artifacts/`.

- [ ] **Step 2: Generate the keypair**

```bash
<path-to>/generate_keys
```
Expected output: prints a confirmation that the private key was stored in the macOS Keychain (as a generic password named "https://sparkle-project.org" with account "ed25519"), and prints the **base64 public key** to stdout.

- [ ] **Step 3: Capture the public key**

Copy the base64 public-key string (it's a 44-character ending-in-`=` line). Save it temporarily as `.sparkle-public-key` (gitignored — DO NOT commit):

```bash
echo "PASTE_PUBLIC_KEY_HERE" > .sparkle-public-key
echo ".sparkle-public-key" >> .gitignore
```

- [ ] **Step 4: Export the private key for backup**

```bash
<path-to>/generate_keys -x rubien-sparkle-private.key
```
This writes the private key to a local file. **Move it to 1Password as a secure note attachment AND a copy to an offline encrypted USB drive.** Then `rm rubien-sparkle-private.key` so it never gets accidentally committed.

- [ ] **Step 5: Verify the keychain entry**

```bash
security find-generic-password -s "https://sparkle-project.org" -a "ed25519" -g 2>&1 | grep -E "service|account"
```
Expected: shows the keychain entry exists.

- [ ] **Step 6: Commit the .gitignore update only**

```bash
git add .gitignore
git commit -m "gitignore: exclude .sparkle-public-key (temp staging file)

The public key itself is safe to commit (it ships in Info.plist),
but the staging file pattern is here so a slip-up doesn't push
the eventual private key by mistake."
```

### Task 9: Create UpdaterProtocol.swift (testability abstraction)

**Files:**
- Create: `Sources/Rubien/Services/Updates/UpdaterProtocol.swift`

- [ ] **Step 1: Create the protocol**

```swift
#if Sparkle
import Foundation
import Sparkle

/// Narrow abstraction over `SPUUpdater` used by `UpdateController` so unit
/// tests can drive the controller with a fake without spinning up real
/// Sparkle XPC services. Only the surface the controller actually reads
/// is exposed; the controller never imports Sparkle directly through this
/// protocol so substitution at test time is straightforward.
@MainActor
protocol UpdaterProtocol: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }

    func checkForUpdates()
    func checkForUpdatesInBackground()
}

extension SPUUpdater: UpdaterProtocol {
    // SPUUpdater already exposes every member of UpdaterProtocol with the
    // same names. Empty extension to declare conformance.
}
#endif
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build 2>&1 | tail -10
```
Expected: builds cleanly. If `Cannot find type 'SPUUpdater'` shows up, the Sparkle product wasn't pulled in — re-check Task 2.

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Services/Updates/UpdaterProtocol.swift
git commit -m "Sparkle: add UpdaterProtocol abstraction over SPUUpdater for tests"
```

### Task 10: Create UpdateUserDriverDelegate with tests

**Files:**
- Create: `Sources/Rubien/Services/Updates/UpdateUserDriverDelegate.swift`
- Create: `Tests/RubienTests/UpdateUserDriverDelegateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RubienTests/UpdateUserDriverDelegateTests.swift`:

```swift
#if canImport(Sparkle)
import XCTest
import Sparkle
@testable import Rubien

final class UpdateUserDriverDelegateTests: XCTestCase {
    @MainActor
    func testScheduledUpdateInvokesCallbackAndSuppressesUI() throws {
        let delegate = UpdateUserDriverDelegate()
        var capturedVersion: String?
        delegate.onUpdateReady = { capturedVersion = $0 }

        let item = try SUAppcastItem(
            dictionary: [
                "version": "2",
                "shortVersionString": "0.1.1",
                "enclosure": [
                    "url": "https://example.invalid/Rubien-0.1.1.dmg",
                    "sparkle:edSignature": "abc=",
                    "length": "100"
                ] as [String: Any]
            ] as [AnyHashable: Any],
            relativeTo: nil,
            stateResolver: nil
        )

        let suppressed = delegate.standardUserDriverShouldHandleShowingScheduledUpdate(
            item,
            andInImmediateFocus: false
        )

        XCTAssertFalse(suppressed, "Delegate must return false to suppress Sparkle's default UI for scheduled checks")
        XCTAssertEqual(capturedVersion, "0.1.1", "Callback must fire with the appcast item's shortVersionString")
    }
}
#endif
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
swift test --filter RubienTests.UpdateUserDriverDelegateTests
```
Expected: FAIL with "no such module" or "Cannot find type 'UpdateUserDriverDelegate'".

- [ ] **Step 3: Implement UpdateUserDriverDelegate**

Create `Sources/Rubien/Services/Updates/UpdateUserDriverDelegate.swift`:

```swift
#if Sparkle
import Foundation
import Sparkle

/// Sparkle delegate that suppresses the framework's default update window
/// for *scheduled* background checks. User-initiated checks (via
/// `SPUUpdater.checkForUpdates()`) are intentionally NOT suppressed and
/// will fall through to Sparkle's standard interactive UI — the silent
/// path is reserved for the background-download UX.
@MainActor
final class UpdateUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Invoked when a scheduled update is ready. The string is the appcast
    /// item's `shortVersionString` (e.g., "0.1.1"). `UpdateController`
    /// observes this to flip its `updateReadyToInstall` flag.
    var onUpdateReady: ((String) -> Void)?

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        onUpdateReady?(update.displayVersionString)
        return false  // Suppress Sparkle's default UI; our SwiftUI surfaces handle it.
    }
}
#endif
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
swift test --filter RubienTests.UpdateUserDriverDelegateTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Services/Updates/UpdateUserDriverDelegate.swift Tests/RubienTests/UpdateUserDriverDelegateTests.swift
git commit -m "Sparkle: add UpdateUserDriverDelegate that suppresses scheduled-check UI

Returning false from standardUserDriverShouldHandleShowingScheduledUpdate
tells Sparkle not to show its default 'Update available' window for
background-discovered updates. The onUpdateReady callback fires so the
@Observable UpdateController can drive its own SwiftUI surfaces.
User-initiated checks (Settings → Check Now) are NOT suppressed — by
design, an explicit click deserves an explicit response."
```

### Task 11: Create UpdateController with tests (TDD)

**Files:**
- Create: `Sources/Rubien/Services/Updates/UpdateController.swift`
- Create: `Tests/RubienTests/UpdateControllerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/RubienTests/UpdateControllerTests.swift`:

```swift
#if canImport(Sparkle)
import XCTest
@testable import Rubien

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testInitialStateIsClean() {
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)

        XCTAssertFalse(controller.updateReadyToInstall)
        XCTAssertNil(controller.pendingVersion)
    }

    func testUpdateReadyFlipsWhenDelegateFires() {
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)

        controller.simulateDelegateUpdateReady(version: "0.1.1")

        XCTAssertTrue(controller.updateReadyToInstall)
        XCTAssertEqual(controller.pendingVersion, "0.1.1")
    }

    func testCheckNowCallsUpdater() {
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)

        controller.checkNow()

        XCTAssertEqual(fake.checkForUpdatesCallCount, 1)
    }

    func testAutomaticallyChecksRoundTrip() {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        let controller = UpdateController(updater: fake)

        controller.automaticallyChecks = false
        XCTAssertFalse(fake.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyChecks)
    }

    func testAutomaticallyDownloadsRoundTrip() {
        let fake = FakeUpdater()
        fake.automaticallyDownloadsUpdates = true
        let controller = UpdateController(updater: fake)

        controller.automaticallyDownloads = false
        XCTAssertFalse(fake.automaticallyDownloadsUpdates)
        XCTAssertFalse(controller.automaticallyDownloads)
    }

    func testDelegateIsStronglyRetained() {
        // Regression test: SPUStandardUpdaterController holds delegates weakly.
        // If UpdateController's delegate property is weak, the delegate is
        // deallocated right after init and update-ready signals never fire.
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)

        XCTAssertNotNil(controller.delegateForTesting, "Delegate must be alive after init")
    }
}

@MainActor
final class FakeUpdater: UpdaterProtocol {
    var automaticallyChecksForUpdates: Bool = false
    var automaticallyDownloadsUpdates: Bool = false
    var canCheckForUpdates: Bool = true
    var lastUpdateCheckDate: Date? = nil

    var checkForUpdatesCallCount = 0
    var checkForUpdatesInBackgroundCallCount = 0

    func checkForUpdates() { checkForUpdatesCallCount += 1 }
    func checkForUpdatesInBackground() { checkForUpdatesInBackgroundCallCount += 1 }
}
#endif
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
swift test --filter RubienTests.UpdateControllerTests
```
Expected: FAIL with "Cannot find type 'UpdateController'".

- [ ] **Step 3: Implement UpdateController**

Create `Sources/Rubien/Services/Updates/UpdateController.swift`:

```swift
#if Sparkle
import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController {
    /// Whether the underlying updater is in a state where checkForUpdates()
    /// can be called right now. Mirrors `SPUUpdater.canCheckForUpdates`.
    private(set) var canCheckForUpdates: Bool = false

    /// True when a scheduled-check download has completed and the user can
    /// click "Install and Relaunch" from any of the SwiftUI surfaces.
    private(set) var updateReadyToInstall: Bool = false

    /// The shortVersionString of the pending update; surfaced as "Update 0.1.1
    /// ready to install" in the Settings pane and toolbar tooltip.
    private(set) var pendingVersion: String?

    /// Timestamp of the last completed scheduled check, used for the
    /// "Last checked: …" Settings status line. Updated via KVO on the
    /// underlying updater.
    private(set) var lastCheckDate: Date?

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    private let updater: any UpdaterProtocol

    // Strongly retained — SPUStandardUpdaterController stores delegates as
    // weak references, so the delegate must outlive init by being owned here.
    private let userDriverDelegate: UpdateUserDriverDelegate

    // Strongly retained in production. Nil in tests (where a FakeUpdater is
    // injected directly and there's no SPUStandardUpdaterController to keep
    // alive). Threaded through the designated init from the convenience init
    // below.
    private let standardController: SPUStandardUpdaterController?

    /// Designated init. Tests pass a FakeUpdater + their own delegate and
    /// nil standardController. Production goes through the convenience init.
    init(
        updater: any UpdaterProtocol,
        userDriverDelegate: UpdateUserDriverDelegate = UpdateUserDriverDelegate(),
        standardController: SPUStandardUpdaterController? = nil
    ) {
        self.updater = updater
        self.userDriverDelegate = userDriverDelegate
        self.standardController = standardController
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.lastCheckDate = updater.lastUpdateCheckDate

        // Wire the callback ONCE here, regardless of which init path was
        // taken. Captures self weakly to avoid a retain cycle.
        userDriverDelegate.onUpdateReady = { [weak self] version in
            self?.updateReadyToInstall = true
            self?.pendingVersion = version
        }
    }

    func checkNow() {
        updater.checkForUpdates()
    }

    func installAndRelaunch() {
        // Triggering checkForUpdates() while an update is downloaded causes
        // Sparkle to present its install path; for v1 we use this single
        // entry point. A dedicated installNow() can replace it later if
        // needed.
        updater.checkForUpdates()
    }

    // MARK: - Testing hooks

    #if DEBUG
    /// Test-only accessor so unit tests can assert the delegate is alive
    /// after init (regression for the weak-reference foot-gun).
    var delegateForTesting: UpdateUserDriverDelegate { userDriverDelegate }

    /// Test-only simulator for the delegate callback path.
    func simulateDelegateUpdateReady(version: String) {
        userDriverDelegate.onUpdateReady?(version)
    }
    #endif
}
#endif
```

The `standardController` property is reserved here (initialized to `nil` in the test path) so Task 12's convenience init can populate it without changing the existing API surface. Tests do not need to construct an `SPUStandardUpdaterController` — they continue to pass a `FakeUpdater` and rely on the default arguments.

- [ ] **Step 4: Run tests, verify they pass**

```bash
swift test --filter RubienTests.UpdateControllerTests
```
Expected: PASS (all six test methods).

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Services/Updates/UpdateController.swift Tests/RubienTests/UpdateControllerTests.swift
git commit -m "Sparkle: add @Observable UpdateController wrapping SPUUpdater

Holds the user-driver delegate as a strong stored property to survive
SPUStandardUpdaterController's weak delegate reference (the delegate
retention test is the regression guard). Exposes updateReadyToInstall
+ pendingVersion for SwiftUI surfaces, plus automaticallyChecks /
automaticallyDownloads as passthrough toggles for the Settings pane."
```

### Task 12: Add production convenience init for SPUStandardUpdaterController

Task 11's designated init already accepts an optional `standardController:` parameter and threads it into the private stored property. This task adds the convenience init that production code uses (`UpdateController()` with no arguments) — it constructs and owns a `SPUStandardUpdaterController` and passes both it and its delegate into the designated init in one go.

**Files:**
- Modify: `Sources/Rubien/Services/Updates/UpdateController.swift`

- [ ] **Step 1: Add the convenience init**

In `UpdateController.swift`, after the designated `init(updater:userDriverDelegate:standardController:)` declaration, add:

```swift
    /// Production init. Constructs an SPUStandardUpdaterController and
    /// threads both it and its delegate through the designated init in a
    /// single call, so:
    ///   - the delegate is owned strongly by self.userDriverDelegate
    ///     (SPUStandardUpdaterController only holds it weakly)
    ///   - the controller is owned strongly by self.standardController
    ///     (without this, the SPUUpdater we delegate to would lose its
    ///     parent controller as soon as this init returned)
    convenience init() {
        let delegate = UpdateUserDriverDelegate()
        let standard = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: delegate
        )
        self.init(
            updater: standard.updater,
            userDriverDelegate: delegate,
            standardController: standard
        )
    }
```

The designated init wires `delegate.onUpdateReady` once, so no further setup is needed after `self.init(...)` returns.

- [ ] **Step 2: Verify build and tests still pass**

```bash
swift build && swift test --filter RubienTests.UpdateControllerTests
```
Expected: clean build, all 6 tests pass. (Tests construct `UpdateController(updater: FakeUpdater())` — the default values for `userDriverDelegate` and `standardController` mean test code doesn't change.)

- [ ] **Step 3: Add a smoke test for the convenience init**

Append to `Tests/RubienTests/UpdateControllerTests.swift`, inside the class:

```swift
    func testConvenienceInitProducesAliveController() {
        // Smoke test: the convenience init must produce a controller whose
        // underlying SPUStandardUpdaterController is retained, otherwise
        // SPUUpdater is orphaned and background checks never fire.
        let controller = UpdateController()
        XCTAssertNotNil(controller.delegateForTesting,
            "Delegate must be alive after convenience init")
        // We can't directly assert on the private standardController, but
        // canCheckForUpdates being accessible (and not crashing) is the
        // observable proof that the SPUUpdater chain is intact.
        _ = controller.canCheckForUpdates
    }
```

- [ ] **Step 4: Run the new test**

```bash
swift test --filter RubienTests.UpdateControllerTests.testConvenienceInitProducesAliveController
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Services/Updates/UpdateController.swift Tests/RubienTests/UpdateControllerTests.swift
git commit -m "UpdateController: add production convenience init wiring SPUStandardUpdaterController

The designated init from Task 11 already accepts an optional
standardController parameter; the convenience init constructs the
SPUStandardUpdaterController and its delegate, then threads both into
the designated init in a single call. Both delegate and controller
are strongly retained (Sparkle holds delegates weakly, so without our
strong retention they'd deallocate immediately after init). The
smoke test exercises the convenience path end-to-end."
```

### Task 13: Inject UpdateController into RubienApp

**Files:**
- Modify: `Sources/Rubien/RubienApp.swift`

- [ ] **Step 1: Add a state property for the controller**

In `RubienApp.swift`, alongside `@StateObject private var syncCoordinator`, add (gated by `#if Sparkle`):

```swift
#if Sparkle
    @State private var updateController = UpdateController()
#endif
```

- [ ] **Step 2: Inject into the SwiftUI environment**

Inside `ContentView()` modifiers chain in `body`, after `.environmentObject(syncCoordinator)`, add:

```swift
                #if Sparkle
                .environment(updateController)
                #endif
```

(Note: `.environment(_:)` for `@Observable` types, not `.environmentObject(_:)` which is for `ObservableObject`. The compiler will tell you if you confuse them.)

- [ ] **Step 3: Build and launch the app**

```bash
swift run Rubien
```
Expected: app launches normally, no behavior change yet (Sparkle is initialized but no UI surfaces it yet). Look in Console.app for "Sparkle" log lines — you should see initialization messages.

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien/RubienApp.swift
git commit -m "RubienApp: instantiate and inject UpdateController via SwiftUI environment

Gated by #if Sparkle. SPUStandardUpdaterController starts checking
for updates in the background as soon as the app launches, against
the appcast URL stamped into Info.plist by build-app.sh (which the
next phase wires up)."
```

---

## Phase 5 — SwiftUI surfaces

### Task 14: Create UpdateIndicator (toolbar badge)

**Files:**
- Create: `Sources/Rubien/Views/Updates/UpdateIndicator.swift`

- [ ] **Step 1: Create the view**

```swift
#if Sparkle
import SwiftUI

struct UpdateIndicator: View {
    @Environment(UpdateController.self) private var updater

    var body: some View {
        if updater.updateReadyToInstall {
            Button {
                updater.installAndRelaunch()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
            }
            .help("Update to \(updater.pendingVersion ?? "—") ready — click to install and relaunch")
            .accessibilityLabel("Install update and relaunch")
        }
    }
}
#endif
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/Updates/UpdateIndicator.swift
git commit -m "Sparkle: add UpdateIndicator toolbar badge

Renders only when an update is downloaded and ready. Clicking triggers
the install-and-relaunch flow."
```

### Task 15: Add UpdateIndicator to main library window toolbar

**Files:**
- Modify: `Sources/Rubien/Views/ContentView.swift`

- [ ] **Step 1: Locate the toolbar in ContentView**

```bash
grep -n "toolbar\|ToolbarItem\|.toolbar(" Sources/Rubien/Views/ContentView.swift | head -20
```
Identify the existing `.toolbar { ... }` modifier on the main view. (If there's more than one, pick the one attached to the library window's root view — there should be a leading or principal item set already.)

- [ ] **Step 2: Add UpdateIndicator as a trailing toolbar item**

Inside the existing `.toolbar { ... }` block, add:

```swift
#if Sparkle
                ToolbarItem(placement: .primaryAction) {
                    UpdateIndicator()
                }
#endif
```

If there's no existing `.toolbar { }` on the main view, add a new one. (Read the file carefully first — the project uses several toolbar attachments across views; the library window's primary toolbar is the right home.)

- [ ] **Step 3: Build and run, verify no regression**

```bash
swift run Rubien
```
Expected: app launches, library window appears, no visible difference (the indicator is hidden until an update is ready).

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien/Views/ContentView.swift
git commit -m "ContentView: add UpdateIndicator to library window toolbar

The indicator is invisible until updateReadyToInstall is true; no
existing toolbar items move. Sparkle-trait-gated."
```

### Task 16: Add "Restart to Install Update" app-menu command

**Files:**
- Create: `Sources/Rubien/Views/Updates/UpdateMenuCommands.swift`
- Modify: `Sources/Rubien/RubienApp.swift`

- [ ] **Step 1: Create the Commands struct**

```swift
#if Sparkle
import SwiftUI

struct UpdateMenuCommands: Commands {
    @FocusedValue(\.updateController) private var updateController

    var body: some Commands {
        CommandGroup(before: .appTermination) {
            Button("Restart to Install Update") {
                updateController?.installAndRelaunch()
            }
            .disabled(updateController?.updateReadyToInstall != true)
            .keyboardShortcut(.init("R"), modifiers: [.command, .shift])
        }
    }
}

private struct UpdateControllerFocusedValueKey: FocusedValueKey {
    typealias Value = UpdateController
}

extension FocusedValues {
    var updateController: UpdateController? {
        get { self[UpdateControllerFocusedValueKey.self] }
        set { self[UpdateControllerFocusedValueKey.self] = newValue }
    }
}
#endif
```

- [ ] **Step 2: Wire focused-value publishing in RubienApp**

In `RubienApp.swift`, attach the focused-value publisher to `ContentView()`:

```swift
                #if Sparkle
                .focusedSceneValue(\.updateController, updateController)
                #endif
```

And add the Commands block to the WindowGroup scene:

```swift
        WindowGroup {
            ContentView()
                // ... existing modifiers ...
        }
        #if Sparkle
        .commands {
            UpdateMenuCommands()
        }
        #endif
```

(The `.commands { }` modifier attaches to the `Scene`, not to `ContentView`. Make sure the `#if Sparkle` block wraps just the `.commands` call, outside the WindowGroup closure.)

- [ ] **Step 3: Build and run**

```bash
swift run Rubien
```
Expected: app launches, Rubien menu contains "Restart to Install Update" item (greyed out — no update ready). The ⇧⌘R shortcut binds.

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien/Views/Updates/UpdateMenuCommands.swift Sources/Rubien/RubienApp.swift
git commit -m "Sparkle: add 'Restart to Install Update' menu item with ⇧⌘R

Disabled when no update is pending. Located in the Rubien menu just
above 'Quit' via CommandGroup(before: .appTermination)."
```

### Task 17: Create UpdateSettingsView (Settings → Updates pane)

**Files:**
- Create: `Sources/Rubien/Views/Updates/UpdateSettingsView.swift`

- [ ] **Step 1: Create the view**

```swift
#if Sparkle
import SwiftUI

struct UpdateSettingsView: View {
    @Environment(UpdateController.self) private var updater

    var body: some View {
        @Bindable var updaterBinding = updater

        Form {
            Section("Software Update") {
                LabeledContent("Current version") {
                    Text(versionLabel)
                        .foregroundStyle(.secondary)
                }

                Toggle("Automatically check for updates", isOn: $updaterBinding.automaticallyChecks)
                Toggle("Automatically download updates", isOn: $updaterBinding.automaticallyDownloads)

                HStack {
                    Text("Last checked")
                    Spacer()
                    Text(lastCheckedLabel)
                        .foregroundStyle(.secondary)
                    Button("Check Now") { updater.checkNow() }
                        .disabled(!updater.canCheckForUpdates)
                }

                if updater.updateReadyToInstall {
                    HStack {
                        Text("Update \(updater.pendingVersion ?? "—") ready to install")
                        Spacer()
                        Button("Install and Relaunch…") { updater.installAndRelaunch() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        return "Rubien \(short) (Alpha)"
    }

    private var lastCheckedLabel: String {
        guard let date = updater.lastCheckDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
#endif
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/Updates/UpdateSettingsView.swift
git commit -m "Sparkle: add UpdateSettingsView with toggles, Check Now, Install & Relaunch

Bindable @Observable controller drives the toggle states; the
'Install and Relaunch…' button is only rendered when an update
is ready. Shows 'Rubien <version> (Alpha)' until first stable
release graduates to 1.0.0."
```

### Task 18: Wire UpdateSettingsView into RubienSettingsView

**Files:**
- Modify: `Sources/Rubien/Views/RubienSettingsView.swift`

- [ ] **Step 1: Find the settings tab structure**

```bash
grep -n "TabView\|tabItem\|Section\|navigationTitle" Sources/Rubien/Views/RubienSettingsView.swift | head -30
```
Identify how the settings root view structures its panes (TabView with tabItem, or NavigationSplitView with sidebar entries, etc.).

- [ ] **Step 2: Add the Updates section**

Add to the settings root view (matching the existing pane structure). For a `TabView`:

```swift
#if Sparkle
            UpdateSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)  // if there's an enum; otherwise omit .tag
#endif
```

If there's a `SettingsTab` enum, add a case `updates` to it. If the settings root uses NavigationSplitView, add the `UpdateSettingsView()` as a destination with a matching sidebar entry.

- [ ] **Step 3: Build and verify the tab appears**

```bash
swift run Rubien
```
Open Settings (⌘,). The Updates tab should appear and show the empty-state pane.

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien/Views/RubienSettingsView.swift
git commit -m "Settings: surface UpdateSettingsView as Updates tab"
```

---

## Phase 6 — Info.plist Sparkle keys via build script

### Task 19: Inject Sparkle keys into Info.plist for the dmg flavor

**Files:**
- Modify: `scripts/build-app.sh`

- [ ] **Step 1: Read the public key staged in Task 8**

```bash
cat .sparkle-public-key
```
Expected: a 44-character base64 string ending in `=`.

- [ ] **Step 2: Add a Sparkle-stamping function to build-app.sh**

In `scripts/build-app.sh`, after the existing `stamp_info_plist_version` function (added in Task 4), add:

```bash
stamp_sparkle_info_plist() {
    [ "$FLAVOR" = "dmg" ] || return 0   # MAS flavor: no Sparkle, no keys

    local plist="$APP_BUNDLE/Contents/Info.plist"
    local pubkey_file="$PROJECT_DIR/.sparkle-public-key"

    if [ ! -f "$pubkey_file" ]; then
        echo "✗ Missing .sparkle-public-key — generate with Sparkle's generate_keys tool" >&2
        exit 1
    fi
    local pubkey
    pubkey="$(cat "$pubkey_file" | tr -d '[:space:]')"

    /usr/bin/plutil -replace SUFeedURL -string                       "https://devzhk.github.io/Rubien/appcast.xml" "$plist"
    /usr/bin/plutil -replace SUPublicEDKey -string                   "$pubkey"                                     "$plist"
    /usr/bin/plutil -replace SUEnableAutomaticChecks -bool           YES                                           "$plist"
    /usr/bin/plutil -replace SUAutomaticallyUpdate -bool             YES                                           "$plist"
    /usr/bin/plutil -replace SUScheduledCheckInterval -integer       86400                                         "$plist"
    /usr/bin/plutil -replace SUEnableInstallerLauncherService -bool  YES                                           "$plist"

    echo "   ✓ Stamped Sparkle Info.plist keys (feed: production)"
}
```

Then in `assemble_app_bundle`, add `stamp_sparkle_info_plist` immediately after the existing `stamp_info_plist_version` call at the bottom of the function. Because Task 4 restructured `assemble_app_bundle` with `if/else` (no early `return`), the stamp functions run for both the xcodebuild-produced and heredoc-fallback paths.

- [ ] **Step 3: Build the app and verify keys are stamped**

```bash
./scripts/build-app.sh debug
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" build/Rubien.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" build/Rubien.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :SUEnableInstallerLauncherService" build/Rubien.app/Contents/Info.plist
```
Expected: each prints the expected value (URL, base64 key, `true`).

- [ ] **Step 4: Commit**

```bash
git add scripts/build-app.sh
git commit -m "build-app.sh: inject Sparkle Info.plist keys for dmg flavor

SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks=YES,
SUAutomaticallyUpdate=YES, SUScheduledCheckInterval=86400,
SUEnableInstallerLauncherService=YES. Reads the public key from
.sparkle-public-key (gitignored). MAS flavor early-returns without
stamping."
```

---

## Phase 7 — Code signing pipeline rewrite

### Task 20: Switch codesign helper AND direct calls to --timestamp + hardened runtime

**Files:**
- Modify: `scripts/lib/codesign.sh`
- Modify: `scripts/build-app.sh` (the `sign_bundle` function around lines 151-156 has direct `codesign` calls outside the helper)

- [ ] **Step 1: Replace --timestamp=none in codesign.sh's `rubien_codesign_binary`**

In `scripts/lib/codesign.sh`, change every `--timestamp=none` to `--timestamp`, and add `--options runtime` to both branches. Final form of `rubien_codesign_binary`:

```bash
rubien_codesign_binary() {
    local target="$1"
    local entitlements="${2:-}"
    if [ -n "$entitlements" ] && [ -f "$entitlements" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$entitlements" \
            --options runtime \
            --timestamp "$target"
    else
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --options runtime \
            --timestamp "$target"
    fi
}
```

- [ ] **Step 2: Update the direct codesign calls in build-app.sh's `sign_bundle`**

`scripts/build-app.sh` has two direct `codesign` invocations inside the `sign_bundle` function (currently around lines 151-156) for the outer app bundle, both using `--timestamp=none`. The no-entitlements branch additionally lacks `--options runtime`. Replace the conditional with:

```bash
    if [ -n "$CODESIGN_ENTITLEMENTS" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$CODESIGN_ENTITLEMENTS" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    else
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    fi
```

- [ ] **Step 3: Verify with a Developer ID build**

This requires `CODESIGN_IDENTITY` set to the Developer ID identity from prerequisites P1:

```bash
export CODESIGN_IDENTITY="Developer ID Application: <Your Name> (9TXK4V3SS8)"
./scripts/build-app.sh release
codesign -dv --verbose=4 build/Rubien.app 2>&1 | grep -E "Authority|Timestamp|Runtime"
```
Expected: shows your Developer ID authority chain, an Apple Timestamp Authority signature, and `flags=0x10000(runtime)`.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/codesign.sh scripts/build-app.sh
git commit -m "codesign: switch from --timestamp=none to --timestamp + hardened runtime everywhere

Both the rubien_codesign_binary helper (used for the embedded CLI)
and the direct codesign calls in sign_bundle (for the outer app
bundle) now use Apple-timestamped signatures and --options runtime.
Required for notarization, which rejects ad-hoc-timestamped or
non-hardened-runtime binaries."
```

### Task 21: Rewrite codesign.sh with ordered Sparkle component signing

**Files:**
- Modify: `scripts/lib/codesign.sh`

- [ ] **Step 1: Add the Sparkle-signing function**

Append to `scripts/lib/codesign.sh`:

```bash
# Sign the five components inside Sparkle.framework, in the order Sparkle's
# official sandboxing guide mandates. Downloader.xpc needs the special
# --preserve-metadata=entitlements flag — a generic re-sign would strip
# Sparkle's pre-signed entitlements on that XPC service. Never use --deep
# anywhere in this function; it corrupts XPC service signatures and is
# the #1 cause of "Failed to gain authorization" errors at runtime.
#
#   $1  Path to the bundled Sparkle.framework (e.g. .../Rubien.app/Contents/Frameworks/Sparkle.framework)
rubien_codesign_sparkle_framework() {
    local fw="$1"

    if [ ! -d "$fw" ]; then
        echo "✗ Sparkle.framework not found at $fw" >&2
        exit 1
    fi

    echo "   ▸ Signing Sparkle.framework components in order…"

    # Versions/B is the canonical version directory in Sparkle 2.7+.
    # If this stops resolving, double-check the framework structure.
    local versions_dir="$fw/Versions/B"
    if [ ! -d "$versions_dir" ]; then
        # Fall back to whichever version directory exists.
        versions_dir="$(find "$fw/Versions" -maxdepth 1 -mindepth 1 -type d ! -name "Current" | head -1)"
    fi

    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$versions_dir/XPCServices/Installer.xpc"
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        --preserve-metadata=entitlements \
        "$versions_dir/XPCServices/Downloader.xpc"
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$versions_dir/Autoupdate"
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$versions_dir/Updater.app"
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        "$fw"

    echo "   ✓ Sparkle.framework signed (5 components)"
}
```

- [ ] **Step 2: Wire the call from build-app.sh's `sign_bundle` function**

In `scripts/build-app.sh`, the outer app bundle is signed by direct `codesign` calls inside the `sign_bundle` function (NOT via `rubien_codesign_binary`, which is only used for the embedded CLI helper). Insert the Sparkle-framework signing call into `sign_bundle` BETWEEN the existing `rubien_codesign_binary "$HELPERS_DIR/$CLI_NAME" "$CLI_ENTITLEMENTS"` line and the `if [ -n "$CODESIGN_ENTITLEMENTS" ]` block that signs the outer app bundle:

```bash
    rubien_codesign_binary "$HELPERS_DIR/$CLI_NAME" "$CLI_ENTITLEMENTS"

    # NEW: sign Sparkle.framework components in the order Sparkle's
    # sandboxing docs require, BEFORE the outer app-bundle sign below.
    # Order matters — inner components first, framework wrapper last,
    # outer bundle last of all (handled by the existing if/else below).
    if [ "$FLAVOR" = "dmg" ]; then
        rubien_codesign_sparkle_framework "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi

    # existing outer app-bundle sign:
    if [ -n "$CODESIGN_ENTITLEMENTS" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$CODESIGN_ENTITLEMENTS" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    else
        ...
```

SPM bundles Sparkle.framework into the executable target's `Frameworks/` directory automatically; verify before running with `ls build/Rubien.app/Contents/Frameworks/`. If the path is different (some SPM versions emit `Frameworks/Sparkle.framework/Versions/B` directly, others use `A`), the framework-signing function's `versions_dir` fallback handles that.

- [ ] **Step 3: Run a full Developer ID release build**

```bash
./scripts/build-app.sh release dmg
```
Expected: succeeds. Specifically watch for these lines in order:
```
▸ Signing Sparkle.framework components in order…
   ✓ Sparkle.framework signed (5 components)
```

- [ ] **Step 4: Verify each component is signed**

```bash
APP=build/Rubien.app
for path in \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "$APP/Contents/Frameworks/Sparkle.framework" \
    "$APP"
do
    echo "--- $path"
    codesign --verify --strict --verbose=2 "$path" 2>&1 | head -3
done
```
Expected: every line emits `<path>: valid on disk` + `satisfies its Designated Requirement`.

- [ ] **Step 5: Verify Downloader.xpc kept its entitlements**

```bash
codesign -d --entitlements - $APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc 2>&1 | head -20
```
Expected: shows non-empty entitlements (network-client etc.). If empty, `--preserve-metadata=entitlements` didn't take — re-verify the codesign command in Step 1.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/codesign.sh scripts/build-app.sh
git commit -m "codesign.sh: ordered five-step Sparkle signing recipe

Signs Installer.xpc, Downloader.xpc, Autoupdate, Updater.app,
then Sparkle.framework — strict order per Sparkle's official
sandboxing docs. Downloader.xpc gets --preserve-metadata=entitlements
so its pre-signed entitlements survive re-signing. Never --deep."
```

---

## Phase 8 — Release pipeline

### Task 22: Bootstrap docs/appcast.xml

**Files:**
- Create: `docs/appcast.xml`

- [ ] **Step 1: Create the directory and skeleton file**

```bash
mkdir -p docs
cat > docs/appcast.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Rubien</title>
        <link>https://devzhk.github.io/Rubien/appcast.xml</link>
        <description>Rubien — releases.</description>
        <language>en</language>
    </channel>
</rss>
XML
```

- [ ] **Step 2: Verify it's valid XML**

```bash
/usr/bin/xmllint --noout docs/appcast.xml && echo "OK"
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add docs/appcast.xml
git commit -m "Bootstrap docs/appcast.xml (empty channel)

GitHub Pages serves this at https://devzhk.github.io/Rubien/appcast.xml.
Each release adds an <item> via scripts/release.sh."
```

### Task 23: Bootstrap docs/staging-appcast.xml

**Files:**
- Create: `docs/staging-appcast.xml`

- [ ] **Step 1: Copy the production appcast as the staging template**

```bash
sed 's|<title>Rubien</title>|<title>Rubien (Staging)</title>|; s|appcast.xml</link>|staging-appcast.xml</link>|' \
    docs/appcast.xml > docs/staging-appcast.xml
```

- [ ] **Step 2: Verify**

```bash
/usr/bin/xmllint --noout docs/staging-appcast.xml && echo "OK"
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add docs/staging-appcast.xml
git commit -m "Bootstrap docs/staging-appcast.xml for end-to-end update tests

Parallel feed at https://devzhk.github.io/Rubien/staging-appcast.xml.
Debug builds with STAGING_FEED=1 point here instead of the production
feed."
```

### Task 24: Bootstrap docs/index.md

**Files:**
- Create: `docs/index.md`

- [ ] **Step 1: Write a minimal landing page**

```markdown
# Rubien

A native macOS reference manager.

**Latest release:** see the [Releases page](https://github.com/devzhk/Rubien/releases/latest).

System requirements: macOS 15.0 (Sequoia) or later.

---

This site hosts the Sparkle update feed for Rubien. End-users do not need to visit this page directly — the app checks for updates automatically.
```

- [ ] **Step 2: Commit**

```bash
git add docs/index.md
git commit -m "Bootstrap docs/index.md as GitHub Pages landing

Linked from the Rubien GitHub README; explains what the /docs path
is for (mostly: hosting the appcast)."
```

### Task 25: Create scripts/lib/appcast.sh

**Files:**
- Create: `scripts/lib/appcast.sh`

- [ ] **Step 1: Write the helper**

```bash
#!/bin/bash
# scripts/lib/appcast.sh — render a Sparkle <item> block and prepend to
# docs/appcast.xml. Sourced by scripts/release.sh.
#
# Required environment variables:
#   VERSION                 — marketing version (e.g. 0.1.1)
#   BUILD_NUMBER            — monotonic integer
#   DMG_PATH                — local path to the signed+notarized+stapled DMG
#   DMG_URL                 — public URL of the DMG on GitHub Releases
#   ED_SIGNATURE            — base64 sparkle:edSignature from sign_update
#   DMG_SIZE_BYTES          — file size in bytes
#   MIN_SYSTEM_VERSION      — sparkle:minimumSystemVersion (e.g. 15.0)
#   RELEASE_NOTES_TEXT      — plain text release notes (escaped for CDATA)
#   APPCAST_PATH            — path to docs/appcast.xml (or staging-appcast.xml)

rubien_appcast_render_item() {
    local pubdate
    pubdate="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"

    cat <<XML
        <item>
            <title>Rubien ${VERSION}</title>
            <description><![CDATA[${RELEASE_NOTES_TEXT}]]></description>
            <pubDate>${pubdate}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
            <enclosure
                url="${DMG_URL}"
                sparkle:edSignature="${ED_SIGNATURE}"
                length="${DMG_SIZE_BYTES}"
                type="application/octet-stream"
            />
        </item>
XML
}

# Prepend the rendered <item> just before </channel> in the given appcast.
# Idempotency: refuses to write if an <item> with the same sparkle:version
# already exists (caller should bump BUILD before re-running).
rubien_appcast_prepend_item() {
    local appcast="$APPCAST_PATH"

    if grep -q "<sparkle:version>${BUILD_NUMBER}</sparkle:version>" "$appcast"; then
        echo "✗ Appcast already has an item with build ${BUILD_NUMBER}; bump BUILD before re-running" >&2
        exit 1
    fi

    local item
    item="$(rubien_appcast_render_item)"

    # Insert the rendered <item> on the line before </channel>.
    /usr/bin/awk -v insert="$item" '
        /<\/channel>/ { print insert }
        { print }
    ' "$appcast" > "$appcast.new"

    mv "$appcast.new" "$appcast"
    /usr/bin/xmllint --noout "$appcast" || { echo "✗ Resulting appcast is not valid XML" >&2; exit 1; }

    echo "   ✓ Prepended <item> for ${VERSION} (build ${BUILD_NUMBER}) to $appcast"
}
```

- [ ] **Step 2: Make it not directly executable (it's source-only)**

It's sourced, not run. No `chmod +x` needed.

- [ ] **Step 3: Smoke-test by sourcing and rendering**

```bash
source scripts/lib/appcast.sh
VERSION=0.1.1 BUILD_NUMBER=2 DMG_URL=https://example.invalid/x.dmg \
ED_SIGNATURE=abc= DMG_SIZE_BYTES=100 MIN_SYSTEM_VERSION=15.0 \
RELEASE_NOTES_TEXT="Test notes" \
rubien_appcast_render_item
```
Expected: prints a valid `<item>` block.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/appcast.sh
git commit -m "appcast.sh: helper to render and prepend a Sparkle <item>

Enumerates all load-bearing fields (sparkle:version,
sparkle:shortVersionString, sparkle:minimumSystemVersion, enclosure
url, sparkle:edSignature, length, type). Idempotency check: refuses
to write a duplicate build number."
```

### Task 26: Create scripts/release.sh orchestrator

**Files:**
- Create: `scripts/release.sh`

- [ ] **Step 1: Write the orchestrator**

```bash
#!/bin/bash
set -euo pipefail
#
# scripts/release.sh — end-to-end Rubien release pipeline.
# Run from a clean working tree on `main` after editing VERSION and (if
# desired) BUILD. The script bumps BUILD if not pre-bumped.
#
# Required env (one-time set up via xcrun notarytool store-credentials):
#   CODESIGN_IDENTITY  — e.g. "Developer ID Application: <Name> (9TXK4V3SS8)"
#
# Optional env:
#   NOTARY_PROFILE      — keychain profile name (default: "RubienNotary")
#   APPCAST_TARGET      — "production" (default) or "staging"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

source "$SCRIPT_DIR/lib/appcast.sh"

NOTARY_PROFILE="${NOTARY_PROFILE:-RubienNotary}"
APPCAST_TARGET="${APPCAST_TARGET:-production}"
case "$APPCAST_TARGET" in
    production) APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml" ;;
    staging)    APPCAST_PATH="$PROJECT_DIR/docs/staging-appcast.xml" ;;
    *) echo "✗ APPCAST_TARGET must be production or staging" >&2; exit 64 ;;
esac
export APPCAST_PATH

# 1. Clean working tree check
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ Working tree not clean; commit or stash first" >&2
    exit 1
fi
if [ "$APPCAST_TARGET" = "production" ] && [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    echo "✗ Production releases must be on main (currently on $(git rev-parse --abbrev-ref HEAD))" >&2
    exit 1
fi

# 2. Read VERSION and BUILD
VERSION="$(cat VERSION | tr -d '[:space:]')"
BUILD_NUMBER="$(cat BUILD | tr -d '[:space:]')"
echo "▸ Releasing Rubien $VERSION (build $BUILD_NUMBER) → $APPCAST_TARGET appcast"

# 3. Build
"$SCRIPT_DIR/build-app.sh" release dmg

DMG_NAME="Rubien-Release.dmg"
DMG_PATH="$PROJECT_DIR/build/$DMG_NAME"
if [ ! -f "$DMG_PATH" ]; then
    echo "✗ Expected DMG not produced at $DMG_PATH" >&2
    exit 1
fi

# 4. Notarize
echo "▸ Submitting $DMG_NAME to notarytool (this can take 5–15 min)…"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json | tee "$PROJECT_DIR/build/notarytool-result.json"

# 5. Staple
echo "▸ Stapling notarization ticket…"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# 6. Per-component signature integrity (catches any --deep slip, missing
#    Sparkle component, or post-hoc tamper). Each line emits 'valid on disk'
#    + 'satisfies its Designated Requirement' or release.sh fails.
APP="$PROJECT_DIR/build/Rubien.app"
FW="$APP/Contents/Frameworks/Sparkle.framework"
for path in \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/Autoupdate" \
    "$FW/Versions/B/Updater.app" \
    "$FW" \
    "$APP"
do
    codesign --verify --strict --verbose=2 "$path"
done

# 7. Belt-and-suspenders deep verification of the assembled app bundle
codesign --verify --deep --strict --verbose=2 "$APP"

# 8. Gatekeeper sanity check on the DMG
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

# 9. EdDSA-sign the DMG
echo "▸ Computing Sparkle EdDSA signature…"
# -perm /111 is portable on macOS BSD find and modern GNU find; -perm +111
# is deprecated on BSD.
SIGN_UPDATE="$(find .build -name 'sign_update' -type f -perm /111 2>/dev/null | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
    echo "✗ sign_update tool not found in .build/. Run swift build first." >&2
    exit 1
fi
SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
# sign_update outputs: sparkle:edSignature="…" length="…"
ED_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
DMG_SIZE_BYTES="$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ] || [ -z "$DMG_SIZE_BYTES" ]; then
    echo "✗ Failed to parse sign_update output:" >&2
    echo "$SIGN_OUTPUT" >&2
    exit 1
fi

# 10. Verify the EdDSA signature round-trips against the public key.
#     sign_update --verify takes <file> <signature> <publickey>.
PUBKEY="$(cat "$PROJECT_DIR/.sparkle-public-key" | tr -d '[:space:]')"
if ! "$SIGN_UPDATE" --verify "$DMG_PATH" "$ED_SIGNATURE" "$PUBKEY" >/dev/null; then
    echo "✗ EdDSA signature verification failed — public key in .sparkle-public-key does not match the private key that signed this DMG" >&2
    exit 1
fi

# 11. Verify the bundled app inside the DMG passes Gatekeeper from inside
#     the mounted image (catches problems that disappear once the user
#     drags-to-Applications). Read-only mount via hdiutil.
MOUNT_POINT="$(mktemp -d -t RubienDmgVerify)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
trap 'hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/Rubien.app"
hdiutil detach "$MOUNT_POINT" -force >/dev/null
trap - EXIT

# 12. Rename DMG to versioned name and prepare URL
VERSIONED_DMG="Rubien-${VERSION}.dmg"
mv "$DMG_PATH" "$PROJECT_DIR/build/$VERSIONED_DMG"
DMG_PATH="$PROJECT_DIR/build/$VERSIONED_DMG"
DMG_URL="https://github.com/devzhk/Rubien/releases/download/v${VERSION}/${VERSIONED_DMG}"
export VERSION BUILD_NUMBER DMG_PATH DMG_URL ED_SIGNATURE DMG_SIZE_BYTES
export MIN_SYSTEM_VERSION="15.0"
export RELEASE_NOTES_TEXT="${RELEASE_NOTES_TEXT:-Rubien ${VERSION} (Alpha). See GitHub release notes for details.}"

# 13. Update appcast
rubien_appcast_prepend_item

# 14. Push appcast change first
git add "$APPCAST_PATH"
git commit -m "Release v${VERSION} (build ${BUILD_NUMBER}): update ${APPCAST_TARGET} appcast"
if [ "$APPCAST_TARGET" = "production" ]; then
    git push origin main
fi

# 15. Create GitHub release with the DMG
if [ "$APPCAST_TARGET" = "production" ]; then
    gh release create "v${VERSION}" "$DMG_PATH" \
        --title "Rubien ${VERSION} — Alpha" \
        --notes "$RELEASE_NOTES_TEXT" \
        --latest
fi

echo "✓ Release $VERSION complete."
echo "   DMG: $DMG_PATH"
echo "   Appcast: $APPCAST_PATH"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/release.sh
```

- [ ] **Step 3: Dry-run readiness check (without notarization)**

For now, only verify the script parses and the working-tree check works:

```bash
bash -n scripts/release.sh && echo "OK: syntax valid"
```
Expected: `OK: syntax valid`. (We won't actually run it end-to-end until Phase 10.)

- [ ] **Step 4: Commit**

```bash
git add scripts/release.sh
git commit -m "release.sh: end-to-end orchestrator with full static verification

Steps: build → notarize → staple → per-component codesign --verify →
deep codesign --verify → spctl → sign_update → sign_update --verify →
mounted-DMG bundle check → appcast update → gh release create.
Reads VERSION and BUILD; supports APPCAST_TARGET=staging for
end-to-end update tests against docs/staging-appcast.xml without
touching the production feed. Production releases require main
branch and push the appcast + create the gh release."
```

---

## Phase 9 — Documentation

### Task 27: Write Docs/Release-Runbook.md

**Files:**
- Create: `Docs/Release-Runbook.md`

- [ ] **Step 1: Write the runbook**

```markdown
# Release Runbook

This is the operator runbook for cutting a Rubien release. The design rationale lives in `Docs/superpowers/specs/2026-05-16-mac-auto-updater-design.md`.

## One-time setup

1. **Apple Developer Program enrollment.** ($99/yr; you already have one as of 2026-05-16.)
2. **Developer ID Application certificate.** Xcode → Settings → Accounts → Manage Certificates → + → "Developer ID Application". Export as `.p12` to 1Password.
3. **EdDSA keypair for Sparkle.** Run `<path-to>/.build/.../bin/generate_keys`. Private key auto-saved to macOS Keychain. Export with `generate_keys -x rubien-sparkle-private.key`, copy to 1Password vault AND an offline encrypted USB drive, then `rm` the local file. Save the printed base64 public key to `.sparkle-public-key` (gitignored).
4. **notarytool keychain profile.** Generate an app-specific password at appleid.apple.com, then `xcrun notarytool store-credentials "RubienNotary" --apple-id you@example.com --team-id 9TXK4V3SS8 --password <app-specific>`.
5. **GitHub Pages.** repo Settings → Pages → Source: Deploy from a branch → Branch: main → Folder: /docs.

## Per-release procedure

```bash
# 1. Make sure working tree is clean and on main
git status
git checkout main && git pull

# 2. Bump the marketing version (if needed) and the build counter
$EDITOR VERSION
$EDITOR BUILD   # increment by 1

# 3. Set the Developer ID identity in your shell
export CODESIGN_IDENTITY="Developer ID Application: <Your Name> (9TXK4V3SS8)"

# 4. Run release.sh
./scripts/release.sh

# 5. Wait for notarization (5-15 minutes). The script blocks.

# 6. Confirm
# - https://github.com/devzhk/Rubien/releases/latest shows the new DMG
# - https://devzhk.github.io/Rubien/appcast.xml has the new <item>
# - Within ~24 hours, existing 0.1.0 installs see the "Update ready" indicator
```

## Staging end-to-end test (before significant updater changes)

1. Build a synthetic 0.1.0 baseline DMG (set VERSION=0.1.0, BUILD=1).
2. Install on a clean macOS Sequoia VM.
3. Bump VERSION to 0.1.1, BUILD to 2.
4. Run `APPCAST_TARGET=staging ./scripts/release.sh` — this pushes to `docs/staging-appcast.xml`, not the production feed.
5. On the test VM, swap `SUFeedURL` in the installed app's `Info.plist` to point at `staging-appcast.xml` (or build a debug variant with that swap baked in).
6. Wait for scheduled check (or trigger via Settings → Check Now to see the user-initiated path).
7. Observe: toolbar badge appears, menu item enables, Settings shows "Update 0.1.1 ready", click "Install and Relaunch" — app swaps and relaunches.
8. About panel shows 0.1.1.

## If a release goes wrong

```bash
# 1. Stop the bleeding
$EDITOR docs/appcast.xml             # delete the bad <item>
git commit -am "Pull v0.1.X from appcast (regression: …)"
git push                              # GitHub Pages updates within ~60s

# 2. Flag the GitHub release publicly
gh release edit v0.1.X --prerelease=true
gh release edit v0.1.X --notes-file pulled.md

# 3. Fix forward — bump VERSION + BUILD, fix the bug, normal release
```

For genuine emergencies (data corruption, crash-on-launch), add `<sparkle:criticalUpdate/>` to the fix-forward `<item>` so Sparkle checks more aggressively.

## EdDSA key compromise — recovery

Sparkle 2 accepts a release where **either** the Developer ID cert OR the EdDSA key changes (but not both). So if the EdDSA private key leaks:

1. Generate a new EdDSA keypair with `generate_keys`.
2. Update `.sparkle-public-key` with the new public key.
3. Cut a release signed with the **new EdDSA key** but the **unchanged Developer ID cert**. Existing clients accept it because the cert chain still validates.
4. All subsequent releases use the new key.
5. Back up the new private key (Keychain + 1Password + offline drive).

Avoid losing both anchors simultaneously by storing them in independent failure domains.

## Cert / notarization edge cases

- **Cert expiration**: no effect on installed apps; renew via Xcode → Settings → Accounts for next release.
- **Cert revocation**: appeal to Apple; ship a release with new cert (single-anchor rotation).
- **Notarization ticket revocation for a specific release**: pull from appcast; ship a re-notarized fix.

## File locations

- `VERSION` — marketing version (CFBundleShortVersionString)
- `BUILD` — monotonic build counter (CFBundleVersion)
- `.sparkle-public-key` — gitignored; base64 EdDSA public key (private key in Keychain + backups)
- `docs/appcast.xml` — production feed (served by GitHub Pages)
- `docs/staging-appcast.xml` — staging feed for end-to-end tests
- `scripts/release.sh` — orchestrator
- `scripts/build-app.sh` — invoked by release.sh; also usable standalone for dev builds
- `scripts/lib/codesign.sh` — ordered Sparkle component signing
- `scripts/lib/appcast.sh` — `<item>` block rendering
```

- [ ] **Step 2: Commit**

```bash
git add Docs/Release-Runbook.md
git commit -m "Add Docs/Release-Runbook.md — operator runbook for cutting releases

Covers one-time setup, per-release procedure, the staging end-to-end
test, the 'pull from appcast' emergency path, and EdDSA key rotation
via Developer-ID dual-trust."
```

### Task 28: Update CLAUDE.md with a Releases section

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Locate the right insertion point**

```bash
grep -n "^##" CLAUDE.md
```
Pick a position near "Tests" or near "Conventions" — the natural reading order is Architecture → Tests → Releases → Conventions.

- [ ] **Step 2: Add a Releases section**

Insert after the Tests section:

```markdown
## Releases

Rubien ships as a signed + notarized DMG via GitHub Releases, with Sparkle 2 auto-update from `docs/appcast.xml` (served by GitHub Pages).

- **Cut a release:** see `Docs/Release-Runbook.md`. Short version: bump `VERSION` (e.g. `0.1.0` → `0.1.1`), bump `BUILD`, run `./scripts/release.sh` from a clean `main`.
- **Sparkle is gated by a package trait** (`Sparkle`, enabled by default in `Package.swift`). DMG builds get it; a future Mac App Store flavor opts out via `swift build --disable-default-traits` so `Sparkle.framework` is absent from the bundle. Don't `import Sparkle` outside `#if Sparkle` blocks.
- **codesign rule:** never `--deep`. Sign Sparkle components individually in the order written in `scripts/lib/codesign.sh`. `Downloader.xpc` specifically needs `--preserve-metadata=entitlements`. Get this wrong and the failure surfaces as opaque "Failed to gain authorization" XPC errors at runtime.
- **Versioning:** `CFBundleShortVersionString` is the `VERSION` file (SemVer 0.x while in alpha, advancing to 1.0.0 at first stable). `CFBundleVersion` is the `BUILD` file (monotonic integer; Sparkle's "is this newer" check uses this, not the marketing version).
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "CLAUDE.md: add Releases section pointing at Release-Runbook"
```

---

## Phase 10 — First-release validation

### Task 29: Staging end-to-end test on a clean macOS Sequoia VM

**Files:**
- None modified (manual operator test against the staging appcast)

- [ ] **Step 1: Provision a clean macOS Sequoia VM**

Use UTM, Parallels, or VMware Fusion to spin up a fresh macOS Sequoia (15.x) VM. Don't reuse a VM that has previously run the dev build — cached signature verification can mask bugs that hit fresh users.

- [ ] **Step 2: Build a synthetic 0.1.0 baseline**

```bash
echo "0.1.0" > VERSION
echo "1"     > BUILD
APPCAST_TARGET=staging ./scripts/release.sh
```

- [ ] **Step 3: Install 0.1.0 on the VM**

Copy `build/Rubien-0.1.0.dmg` to the VM (drag-drop via shared folder, AirDrop, or a temp upload). Open the DMG. Drag to Applications. Launch. Confirm it opens cleanly with no Gatekeeper dialog. Confirm About panel says "Rubien 0.1.0 (Alpha)".

- [ ] **Step 4: Cut a synthetic 0.1.1 release to staging**

Back on the host:
```bash
echo "0.1.1" > VERSION
echo "2"     > BUILD
APPCAST_TARGET=staging ./scripts/release.sh
```

- [ ] **Step 5: On the VM, swap the installed Rubien's SUFeedURL to staging**

In the running 0.1.0 app, the SUFeedURL is baked into `Info.plist`. Quickest path for the test: open Terminal on the VM and run
```bash
/usr/bin/plutil -replace SUFeedURL -string "https://devzhk.github.io/Rubien/staging-appcast.xml" \
    /Applications/Rubien.app/Contents/Info.plist
```
(In production releases we don't do this — we use the production feed. This is staging-test scaffolding only.)

- [ ] **Step 6: Trigger an update check**

Open Rubien → Settings (⌘,) → Updates → Check Now. (The user-initiated path; will show Sparkle's standard "Update available" sheet.)

- [ ] **Step 7: Reset, then test the scheduled-check path**

Quit Rubien. Re-launch. Wait for the scheduled background check (or shorten `SUScheduledCheckInterval` to 60 via `plutil`). Observe:
- Toolbar badge appears (`arrow.down.circle.fill`)
- Rubien menu → "Restart to Install Update" enables
- Settings → Updates shows "Update 0.1.1 ready to install"

- [ ] **Step 8: Install and verify relaunch**

Click any of the three install surfaces. Confirm:
- App quits cleanly
- New app launches without Gatekeeper dialog
- About panel now shows "Rubien 0.1.1 (Alpha)"

- [ ] **Step 9: Roll back the staging artifacts**

```bash
echo "0.1.0" > VERSION
echo "1"     > BUILD
# Manually edit docs/staging-appcast.xml to remove the synthetic 0.1.1 entry
# OR git-checkout docs/staging-appcast.xml to revert to the empty skeleton
git checkout docs/staging-appcast.xml
```

- [ ] **Step 10: Document any issues encountered**

If steps 3–8 had any surprises (Gatekeeper dialog appearing, badge not lighting up, relaunch failing, etc.), file a follow-up task to fix and re-run before proceeding to the public v0.1.0 release. Do not skip to Task 30 with broken staging.

### Task 30: Cut the public v0.1.0 release

**Files:**
- Modify: `VERSION`, `BUILD` (set to 0.1.0 / 1 if not already)

- [ ] **Step 1: Verify clean state**

```bash
git status              # clean
git rev-parse --abbrev-ref HEAD   # main
cat VERSION BUILD       # 0.1.0 / 1
```

- [ ] **Step 2: Set the Developer ID and run release.sh**

```bash
export CODESIGN_IDENTITY="Developer ID Application: <Your Name> (9TXK4V3SS8)"
./scripts/release.sh
```

- [ ] **Step 3: Wait for notarization (~5–15 min)**

The script blocks. Watch for any notary-rejection errors — most common are missing entitlements or unsigned bundled binaries.

- [ ] **Step 4: Verify the GitHub release and appcast**

```bash
gh release view v0.1.0
curl -s https://devzhk.github.io/Rubien/appcast.xml | head -40
```
Expected: release page shows `Rubien-0.1.0.dmg` as an asset; appcast contains an `<item>` whose `<sparkle:version>` matches the `BUILD` value (e.g., `1` for the very first release).

- [ ] **Step 5: Install on the clean VM, confirm**

Download from GitHub Releases via the VM's browser. Install. Launch. Confirm About panel.

- [ ] **Step 6: Done.**

There is no commit step here — `release.sh` already pushed the appcast commit. The v0.1.0 git tag is created by `gh release create` and is visible via `git fetch --tags`.

---

## Self-review (writing-plans skill checklist)

Spot-checked against the spec at `Docs/superpowers/specs/2026-05-16-mac-auto-updater-design.md`:

- **Sparkle 2.7+ as SPM dep with trait gating** → Tasks 1, 2 ✓
- **Background check + silent download + custom UI** → Tasks 10, 11, 14, 15, 16, 17, 18 ✓
- **User-initiated check intentionally NOT suppressed** → Task 10 (only suppresses scheduled), Task 11 (`checkNow()` test) ✓
- **Sandbox entitlements (mach-lookup `-spks`/`-spki`)** → Task 6 ✓
- **`SUEnableDownloaderService` deliberately NOT set; `SUEnableSystemProfiling` not set** → Task 19 (only the explicit keys are stamped) ✓
- **SemVer 0.x marketing + plain `BUILD` counter** → Tasks 3, 4 ✓
- **`com.rubien.app` bundle ID unchanged** → no task changes it ✓
- **swift-tools-version migration 5.9 → 6.1** → Task 1 ✓
- **Ordered five-step codesign without `--deep`, with `--preserve-metadata=entitlements` on Downloader.xpc** → Task 21 ✓
- **`--timestamp` + `--options runtime` for notarization** → Task 20 ✓
- **GitHub Pages serving `docs/appcast.xml` from `main` branch** → P4 + Task 22 ✓
- **Appcast schema with `sparkle:version`, `shortVersionString`, `minimumSystemVersion`, signed enclosure** → Task 25 ✓
- **`release.sh` orchestrator with static verification** → Task 26 (the spctl + stapler validate + sign_update verify pieces are all present) ✓
- **EdDSA keypair backup discipline** → Task 8 + Task 27's runbook ✓
- **Staging end-to-end test pattern** → Tasks 23 + 29 ✓
- **`Docs/Release-Runbook.md`** → Task 27 ✓
- **CLAUDE.md "Releases" section** → Task 28 ✓
- **EdDSA rotation via Developer-ID dual-trust** → Task 27's runbook documents the actual mechanism ✓

No placeholders found. Types are consistent (`UpdaterProtocol`, `UpdateController`, `UpdateUserDriverDelegate`, `UpdateIndicator`, `UpdateMenuCommands`, `UpdateSettingsView` used identically across tasks).

## Codex review 2026-05-16 — findings folded in

Pre-execution review by Codex surfaced four blockers and two real concerns, now reflected in this revision:

1. **Task 11 + Task 12 — `UpdateController` init flow rewritten.** The original convenience init created two delegates (one in convenience, one in designated), never assigned the production `SPUStandardUpdaterController` to the stored property, and the stored property was a `let` that couldn't be reassigned after `self.init`. Restructured: the designated init now takes optional `userDriverDelegate` and `standardController` parameters; the convenience init constructs both and threads them through in a single call. Both delegate and controller are strongly retained.
2. **Task 4 — `assemble_app_bundle` restructured.** Replaced the early `return` in the xcodebuild path with explicit `if/else`, so post-build stamping (version + Sparkle keys) runs regardless of which path created the bundle. Without this, the heredoc-fallback path would silently produce an unstamped bundle.
3. **Task 20 — also updates `build-app.sh:151-156`.** The original task only touched `codesign.sh`, but `build-app.sh`'s `sign_bundle` function has direct `codesign` calls that bypass the helper and were still using `--timestamp=none` (and the no-entitlements branch lacked `--options runtime`). Both branches now use `--options runtime --timestamp`.
4. **Task 21 — fixed the wiring call site.** The original task said "find the existing call to `rubien_codesign_binary` for the app bundle" — but that helper is only used for the embedded CLI. The Sparkle-framework signing now wires into `sign_bundle` between the CLI sign and the direct app-bundle `codesign`, in the correct strict order.
5. **Task 26 — `release.sh` gained the four missing verification steps.** Per-component `codesign --verify --strict` on each Sparkle component, deep verify on the assembled app, `sign_update --verify` to round-trip the EdDSA signature against the public key, and a mounted-DMG `codesign --verify` to catch problems that only manifest from inside the disk image. Also switched `find -perm +111` → `-perm /111` for BSD-find portability and fixed the `mktemp` call to produce an existing mount point.

Plus minor wording fixes: Task 2's "insert after defaultLocalization" → "insert between platforms and products"; Task 4's "after existing variables" → "after the BUNDLE_ID line"; Task 6's incorrect "alphabetical placement" claim removed; Task 30's expected appcast version corrected from `2` to `BUILD` value (e.g., `1` for first release).

One Codex finding (Task 6 path "Resources/Rubien.entitlements") was a quote-back artifact of the review prompt — the plan's path was already correct.
