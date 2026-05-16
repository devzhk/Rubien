# Mac auto-updater — design

**Status:** drafted 2026-05-16; revised after Codex review of same date; ready for implementation plan.
**Scope:** wire Sparkle 2 into the Mac DMG build so users running v0.1.0 (Alpha) and forward receive auto-updates with a Claude-Desktop-style "Relaunch to apply" flow for background checks. Architect the package + entitlements + build pipeline so the future Mac App Store flavor (no Sparkle) and the future iOS target (App Store, no Sparkle) drop in without rework. Establish the release pipeline (Developer ID signing, notarization, EdDSA signing, appcast publishing) as a single `scripts/release.sh` orchestrator.

## Context

Rubien is preparing its first public release: **v0.1.0 (Alpha)**, distributed as a signed + notarized DMG via GitHub Releases. The current `scripts/build-app.sh` produces a DMG but signs ad-hoc (`CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"`), has no notarization step, hardcodes `CFBundleShortVersionString=1.0.0` and `CFBundleVersion=1`, and contains no update mechanism. Users would have to manually re-download a new DMG every release.

The user wants the **Claude Desktop / VS Code / Slack** background-update UX: silent periodic check, silent download, a subtle "Update ready — relaunch" indicator surfaced by our own SwiftUI views, one click to install. Sparkle's default modal release-notes window is suppressed for *scheduled* checks; *user-initiated* checks (via the Settings pane's "Check Now" button) intentionally fall through to Sparkle's standard UI, since asking explicitly implies wanting an interactive response.

Two future constraints shape the design:
1. **Mac App Store** is a planned second distribution channel (post-v1). App Review rejects Mac apps that ship `Sparkle.framework` at all, so the framework must be physically absent from the MAS bundle, not merely code-gated.
2. **iOS** is on the long-horizon roadmap (after MAS). iOS only distributes via the App Store, which handles its own updates. Sparkle never enters the iOS picture; the CloudKit + App Group infrastructure already accommodates cross-platform library sync regardless of Mac distribution channel.

The auto-updater work itself is Mac-DMG-specific. Its main impact on the rest of the codebase is the **release pipeline** — code signing, notarization, version stamping — which all three channels will inherit in some form once they exist.

## Prerequisites

Before any updater code lands, two preparatory changes are required:

1. **Bump `swift-tools-version` in `Package.swift` from `5.9` to `6.1`.** Package Traits (the mechanism that gates the Sparkle dependency for the future MAS flavor) require `swift-tools-version: 6.0` minimum, and the verified-correct trait API uses 6.1 syntax. The toolchain on the build host is already 6.x per `CLAUDE.md`, so this is a manifest change only. Verify a clean `swift build` + `swift test` against `6.1` before proceeding.

2. **Apple Developer Program membership** is in place (confirmed by user, 2026-05-16). Remaining one-time setup: create Developer ID Application certificate via Xcode → Settings → Accounts; create `notarytool` keychain profile named `RubienNotary` via `xcrun notarytool store-credentials`.

## Scope

**In scope (this spec):**

- Add Sparkle 2 (≥ 2.7.0) as an SPM dependency on the `Rubien` target only, gated by a `Sparkle` package trait that is **enabled by default**.
- Background-mode update configuration: silent 24h checks, silent download, custom SwiftUI surfaces for the "update ready" state — suppress Sparkle's default UI window for scheduled checks via `SPUStandardUserDriverDelegate.standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` returning `false`.
- **User-initiated check intentionally NOT suppressed:** the Settings → Updates "Check Now" button calls `SPUUpdater.checkForUpdates()`, which falls through to Sparkle's standard "Update available" sheet. This is by design — explicit checks deserve interactive responses. The "silent" treatment is only for the scheduled background path.
- Three SwiftUI surfaces for the "update ready" indicator (driven by the background path): (a) library-window toolbar badge, (b) "Rubien" app-menu item "Restart to Install Update", (c) Settings → General → Updates pane with toggles + status text + "Check Now" / "Install and Relaunch" buttons.
- Sandboxing-compatible Sparkle setup: `SUEnableInstallerLauncherService=YES`, mach-lookup temporary-exception entitlements for the `-spks` and `-spki` global names. **`SUEnableDownloaderService` is NOT set**, since `Rubien.entitlements` already has `com.apple.security.network.client` and the Downloader XPC service is only needed when the host app lacks network access. (The `Downloader.xpc` binary is still signed because it ships inside `Sparkle.framework`; it simply doesn't run at runtime.)
- **`SUEnableSystemProfiling` is NOT set** (defaults to OFF). Rubien sends no anonymous system-profiling telemetry to Sparkle's stats endpoint. If a future release wants opt-in profiling, it adds a Settings toggle plus the Info.plist key.
- **Versioning model:** SemVer-style `0.x.y` marketing version in `CFBundleShortVersionString`, monotonic `CFBundleVersion` from a **plain `BUILD` file** at the repo root (not derived from `git rev-list --count HEAD`, which is fragile under rebase/squash). The `BUILD` file is hand-bumped or bumped by `release.sh` at release time; the value is a single integer that only ever increases. Pre-release status is conveyed as a UI label ("Alpha") in the About panel and GitHub release title, never as a version-string suffix.
- **Bundle ID:** `com.rubien.app` shared identity across all current and future distribution channels (DMG, MAS, iOS).
- Release-pipeline rewrite:
  - `VERSION` and `BUILD` files at repo root as marketing-version and build-counter sources of truth.
  - `scripts/build-app.sh` reads both files, stamps `Info.plist` at build time via `plutil`. Gains a flavor argument (`dmg` for v1, `mas` reserved for future use). Injects Sparkle Info.plist keys only when building the DMG flavor.
  - `scripts/lib/codesign.sh` rewritten to sign components in strict order — `Installer.xpc → Downloader.xpc → Autoupdate → Updater.app → Sparkle.framework → rubien-cli helper → Rubien.app` — using `--options runtime --timestamp` consistently and **never `--deep`**. Per Sparkle's official sandboxing guide, `Downloader.xpc` additionally requires `--preserve-metadata=entitlements` to avoid stripping its pre-signed entitlement metadata.
  - `scripts/release.sh` (new) orchestrates: clean working-tree check → build → notarize via `xcrun notarytool submit --wait` against keychain profile `RubienNotary` → staple → `sign_update` for EdDSA → append `<item>` to `docs/appcast.xml` → `gh release create` → commit + push appcast.
- **Appcast hosting:** GitHub Pages serving `docs/appcast.xml` on the `main` branch. Stable URL `https://devzhk.github.io/Rubien/appcast.xml`.
- **Binary hosting:** GitHub Releases.
- **EdDSA key management:** keypair generated once via `bin/generate_keys`. Private key stored in macOS Login Keychain + backed up to 1Password + a third copy on an offline encrypted USB drive (independent failure domains). Public key embedded in `Info.plist` as `SUPublicEDKey`.
- **Static release-time verification** in `release.sh`: `codesign --verify --strict --verbose=2` on each signed component individually, `xcrun stapler validate`, `spctl -a -t open --context context:primary-signature -vv`, `sign_update --verify`. Belt-and-suspenders `codesign -vvv` check on the mounted app bundle from inside the assembled DMG before publication. Fail loudly if any check fails.
- **Staging end-to-end test:** a `docs/staging-appcast.xml` sibling and a debug-only build flag `STAGING_FEED=1` that swaps the `SUFeedURL`, so a manual runbook on a clean macOS Sequoia VM exercises the full install-and-relaunch flow before the public appcast is touched.
- **Recovery runbook:** `Docs/Release-Runbook.md` (new) covering one-time setup, per-release procedure, the "pull from appcast" emergency response, EdDSA key rotation via the Developer-ID dual-trust mechanism, and cert/notarization edge cases.

**Out of scope (deferred or explicitly not built):**

- **Mac App Store build pipeline.** Architected — the `Sparkle` trait disables, a separate `Rubien-MAS.entitlements` file is reserved, `build-app.sh mas` exits with "not yet implemented" — but the MAS build flavor itself, Mac App Distribution certificate setup, screenshot/metadata preparation, and App Store Connect submission are a separate work item after v1 ships.
- **iOS target.** Out of scope entirely. CloudKit container, App Group, and shared bundle ID are designed to accommodate it; nothing else.
- **CI automation of `release.sh`.** First few releases are local-only from the maintainer's Mac. Once the pipeline has stabilized over 2–3 releases, a GitHub Actions workflow can wrap `release.sh` with secret-injected credentials. Pre-v1 manual flow is intentional.
- **Sparkle binary delta updates.** Doable via an additional step in `generate_appcast`, but the DMG is small enough for v1 that delta payoff is marginal.
- **Beta / pre-release channel.** Single "stable" appcast for v1.
- **Rich in-app release-notes WebView via `<sparkle:releaseNotesLink>`.** v1 surfaces plain text in the Settings pane status line; GitHub Release notes carry the human-readable changelog.
- **Phased rollout via `<sparkle:phasedRolloutInterval>`.** Available as a one-line `<item>` attribute for future risky releases; not used at v0.1.0.
- **Hardware-backed signing.** Overkill for v1 alpha.
- **Reproducible builds.**
- **Pre-built opt-in anonymous system profiling UI.** `SUEnableSystemProfiling` stays OFF.

## Design choices

### Framework: Sparkle 2 over a DIY updater

Sparkle is the de-facto standard for non-MAS Mac apps. Its EdDSA-signature-on-the-payload security model defeats CDN compromise (a network attacker cannot substitute a malicious DMG even with full HTTPS interception, because the signature is keyed to the developer's private key). A DIY updater that punts to "open the download page" forfeits this property; a DIY updater that re-implements in-place install reproduces months of solved problems.

Sparkle 2.7+ supports macOS 10.13+ (well below Rubien's 15.0 deployment target), ships SPM-first, and is actively maintained. Its sandboxing story uses XPC services bundled inside the framework (since 2.2 — no separate bundling step), and the `SPUStandardUserDriverDelegate` API gives us the hook to suppress Sparkle's default UI for scheduled checks in favor of our own SwiftUI surfaces.

### Distribution: Tier 1 (Developer ID + notarization), DMG only at v1

The Claude-Desktop-style silent-relaunch UX specifically requires Tier 1 signing. The "click Relaunch → app swaps → new version starts" handoff invokes Gatekeeper on the new bundle; for unsigned or unnotarized bundles, Gatekeeper shows the "App could not be verified" dialog every time. macOS Sequoia (15) tightened this further: the Control-click → Open bypass was removed, and Sequoia is the first macOS that *expects* notarization for non-MAS apps. Anything less than Tier 1 would defeat the polish-on-first-impression goal of the alpha release.

### Versioning: SemVer 0.x in marketing string, monotonic counter in build string

`CFBundleShortVersionString` must be three period-separated integers per Apple's docs and Mac App Store Connect validation. Suffixed forms (`1.0.0-alpha.1`, `2026.5.16-alpha`) work for Sparkle's comparator but block MAS submission. Since MAS is on the roadmap, we keep the marketing version MAS-compatible from day one and convey pre-release status as UI chrome (About panel, GitHub release title) rather than version-string content.

- `CFBundleShortVersionString` starts at `0.1.0`, advances toward `1.0.0` at first stable release. Anything under `1.0.0` carries the implicit "API/UX not stable" signal.
- `CFBundleVersion` is the load-bearing string for Sparkle's "is this newer?" check. **Sourced from a plain `BUILD` file at the repo root**, a single integer that `release.sh` bumps (or the maintainer bumps by hand) before each release. `git rev-list --count HEAD` was considered and rejected — squash-merging or rebasing main can decrease the commit count for a release that's strictly newer, and Sparkle would then refuse to offer the update. A plain `BUILD` file decouples version monotonicity from git history shape.

### Trait-gated Sparkle dependency

The MAS build cannot ship `Sparkle.framework` — App Review rejects MAS apps that bundle third-party update mechanisms regardless of whether the code references them. A Swift `#if SPARKLE_ENABLED` compile flag alone is insufficient because the framework still links. We need the SPM **product dependency** itself to be conditional.

The right tool is **SPM Package Traits** (Swift 6.1+ feature). The pattern, with explicit string literals throughout:

```swift
// Package.swift (swift-tools-version: 6.1)
traits: [
    .default(enabledTraits: ["Sparkle"]),
    .init(
        name: "Sparkle",
        description: "Enable Sparkle auto-updater (DMG distribution). Disable for MAS builds."
    ),
],
dependencies: [
    // ... existing dependencies ...
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
],
targets: [
    .executableTarget(
        name: "Rubien",
        dependencies: [
            "RubienCore",
            "RubienSync",
            .product(
                name: "Sparkle",
                package: "Sparkle",
                condition: .when(traits: ["Sparkle"])
            ),
        ],
        swiftSettings: [
            .define("Sparkle", .when(traits: ["Sparkle"])),
        ]
    ),
]
```

DMG builds: trait enabled by default → `swift build` / `xcodebuild` link Sparkle, `#if Sparkle` blocks compile. Future MAS builds: `swift build --disable-default-traits` → framework absent from bundle, `#if Sparkle` blocks compile away.

`xcodebuild` does not yet expose a `--traits` flag directly. v1 sidesteps this by making `Sparkle` a default trait, so xcodebuild picks it up automatically. When the MAS flavor lands, it will either switch that flavor to `swift build --disable-default-traits` or use an xcconfig override via `OTHER_SWIFT_FLAGS`.

### Bundle identity: single `com.rubien.app` across channels

Same bundle ID for Mac DMG, future Mac App Store, and future iOS App Store. Consequences:
- Only one of {DMG-Mac, MAS-Mac} can be installed at a time on a given machine — Mac's bundle-ID uniqueness enforces this. Users switching channels effectively upgrade or downgrade in place, with the same library on disk.
- Shared `iCloud.com.rubien.app` CloudKit container — papers added on iPhone show up on Mac DMG-installed and Mac MAS-installed identically.
- Shared `9TXK4V3SS8.com.rubien.shared` App Group — library, PDF storage, sync state sidecar all colocated regardless of channel.

### Appcast on GitHub Pages, binaries on GitHub Releases

`docs/appcast.xml` on the `main` branch, GitHub Pages serving `/docs`. Stable URL, free hosting, PR diffs show appcast changes, single branch to maintain. Each release adds an `<item>` block via `scripts/release.sh`.

**Why manual appcast editing instead of Sparkle's `generate_appcast` tool:** `generate_appcast` is designed for the workflow of "drop a new DMG into a directory of historical DMGs, regenerate the whole appcast." It's well-suited to projects that keep every historical binary locally. Our pipeline pushes binaries to GitHub Releases (not a local directory) and only ever has the current release on disk during a release. Manual editing — driven by `scripts/lib/appcast.sh` rendering a single `<item>` block from variables and prepending it to the existing XML — is simpler than maintaining a local DMG mirror just to satisfy `generate_appcast`'s convention. We can revisit if multi-channel beta/stable appcasts become a thing.

### Appcast `<item>` schema (load-bearing fields)

Every release's `<item>` block must include these fields exactly — omitting any of them causes Sparkle to silently skip the item (no error, no log, just no offered update):

```xml
<item>
    <title>Rubien 0.1.1</title>
    <description><![CDATA[Plain-text release notes go here, or link to GitHub release.]]></description>
    <pubDate>Sat, 16 May 2026 12:00:00 +0000</pubDate>
    <sparkle:version>2</sparkle:version>                          <!-- matches CFBundleVersion -->
    <sparkle:shortVersionString>0.1.1</sparkle:shortVersionString> <!-- matches CFBundleShortVersionString -->
    <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
    <enclosure
        url="https://github.com/devzhk/Rubien/releases/download/v0.1.1/Rubien-0.1.1.dmg"
        sparkle:edSignature="<base64-from-sign_update>"
        length="<bytes-from-sign_update>"
        type="application/octet-stream"
    />
</item>
```

`sparkle:minimumSystemVersion` matches Rubien's deployment target (currently `15.0`). The build script reads this value from `Package.swift`'s `.macOS(.v15)` declaration to avoid drift.

### Background update UX (the silent-then-prompt path)

Sparkle Info.plist configuration to produce the Claude Desktop UX for *scheduled* checks:

```xml
<key>SUFeedURL</key>           <string>https://devzhk.github.io/Rubien/appcast.xml</string>
<key>SUPublicEDKey</key>       <string>{base64 EdDSA public key}</string>
<key>SUEnableAutomaticChecks</key>          <true/>
<key>SUAutomaticallyUpdate</key>            <true/>
<key>SUScheduledCheckInterval</key>         <integer>86400</integer>
<key>SUEnableInstallerLauncherService</key> <true/>
```

`SUAutomaticallyUpdate=YES` is the load-bearing key: Sparkle downloads the new DMG silently in the background when one is available, then notifies via the delegate that an update is ready. **Caveat:** Sparkle won't silently install if the update requires admin authorization (e.g., bundle moved to a system path). For an app installed in `~/Applications/` or `/Applications/` by the user, the sandboxed installer launcher service handles the swap without prompting. If a user manually moves the app somewhere that requires root, the install falls back to an authorization prompt. We document this as expected behavior in the Settings pane status line ("Update 0.1.1 ready — may prompt for permission").

The custom `SPUStandardUserDriverDelegate` returns `false` from `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`, which tells Sparkle to suppress its default update window **for scheduled checks only**. We capture the "update ready" signal in our delegate and surface it via an `@Observable` `UpdateController` that drives three SwiftUI surfaces:

1. **Library-window toolbar badge** (always visible when `updateReadyToInstall == true`): `arrow.down.circle.fill` icon in `.tint` color with tooltip "Update to 0.1.1 ready — click to install and relaunch."
2. **App menu item** ("Rubien" menu, above the divider before Quit): "Restart to Install Update", enabled only when an update is ready.
3. **Settings → General → Updates pane**: "Current version: Rubien 0.1.0 (Alpha)", toggles for "Automatically check for updates" and "Automatically download updates" (both default ON, bound to `SPUUpdater.automaticallyChecksForUpdates` and `.automaticallyDownloadsUpdates`), "Last checked" status text, "Check Now" button, "Install and Relaunch…" button when ready.

### User-initiated check UX (intentionally NOT suppressed)

When the user clicks "Check Now" in the Settings pane, `UpdateController.checkNow()` calls `SPUUpdater.checkForUpdates()`. **This path bypasses the scheduled-check delegate**, so Sparkle's standard interactive UI fires:
- If no update is available: Sparkle shows a small "You're up to date" alert.
- If an update is available: Sparkle shows its standard "Update available" sheet with "Install Now" / "Install on Quit" / "Skip This Version" buttons.

This is intentional. A user who explicitly clicked "Check Now" has signaled they want an interactive response — the silent-badge UX is for the background case. Documenting this asymmetry up front avoids implementation surprise.

### Appcast unreachable / network-failure behavior

- **Scheduled background check fails** (no network, appcast 404, malformed XML, EdDSA verification failure): silent. The Settings pane status line still shows "Last checked: <previous successful timestamp>". No alert, no badge. Sparkle's internal retry will pick up on the next interval. This avoids spamming users with "couldn't check for updates" alerts when they're on a plane.
- **User-initiated "Check Now" fails**: Sparkle's standard UI shows an error alert ("Update Error — Could not download appcast"). The user explicitly asked, so they get explicit feedback.
- **EdDSA signature verification failure on a downloaded DMG**: Sparkle silently rejects the download and logs to Console. The "update ready" indicator does NOT light up. From the user's perspective, the update simply never arrives. (If the rejection is recurring across multiple users, it would surface as "users on 0.1.0 aren't updating" telemetry, not an end-user UI signal.)

### Code signing: ordered, no `--deep`, with Downloader.xpc preserving entitlements

The dominant failure mode for Sparkle-sandboxed apps is `codesign --deep`, which corrupts the XPC service signatures embedded in `Sparkle.framework`. Sign components individually in strict order per Sparkle's official sandboxing guide:

```bash
# Inside Sparkle.framework/Versions/B/ — order matters
codesign -f -s "$DEV_ID" --options runtime --timestamp                                 \
    Sparkle.framework/Versions/B/XPCServices/Installer.xpc

codesign -f -s "$DEV_ID" --options runtime --timestamp --preserve-metadata=entitlements \
    Sparkle.framework/Versions/B/XPCServices/Downloader.xpc

codesign -f -s "$DEV_ID" --options runtime --timestamp                                 \
    Sparkle.framework/Versions/B/Autoupdate

codesign -f -s "$DEV_ID" --options runtime --timestamp                                 \
    Sparkle.framework/Versions/B/Updater.app

codesign -f -s "$DEV_ID" --options runtime --timestamp                                 \
    Sparkle.framework

# Then our own components
codesign -f -s "$DEV_ID" --options runtime --timestamp                                 \
    Rubien.app/Contents/Helpers/rubien-cli

codesign -f -s "$DEV_ID" --options runtime --timestamp --entitlements Rubien.entitlements \
    Rubien.app

# DMG separately, after assembly
codesign -f -s "$DEV_ID" --options runtime --timestamp Rubien-0.1.0.dmg
```

Critical points (each is a documented foot-gun):
- **`Autoupdate` is a standalone executable**, not a bundle. `Updater.app` is a bundle wrapping a relauncher. Both live inside the framework at `Versions/B/`. Both must be signed individually; missing either fails notarization and breaks the relaunch handoff.
- **`Downloader.xpc` specifically requires `--preserve-metadata=entitlements`.** Sparkle 2.6+ ships it pre-signed with embedded entitlements that a generic re-sign would strip.
- **Never `--deep`.** Don't add it to `OTHER_CODE_SIGN_FLAGS` or any custom script. It corrupts XPC service signatures and is the #1 cause of mysterious "Failed to gain authorization" errors at runtime.

### Sandboxing: mach-lookup temporary-exception entitlements

For Sparkle's XPC services to communicate from a sandboxed parent process, the app's entitlements must include:

```xml
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
</array>
```

Both `-spks` (Installer Launcher Service) and `-spki` (Installer Service) are required; missing either produces opaque "Failed to gain authorization" errors that surface as XPC communication failures rather than entitlement violations. The "temporary-exception" naming is Apple's wording for App Sandbox extensions; these are stable entitlements, not deprecated.

`Rubien.entitlements` already declares `com.apple.security.app-sandbox`, `com.apple.security.network.client`, `com.apple.security.application-groups`, iCloud entitlements, etc. The Sparkle additions are minimal — just the two mach-lookup keys. **`SUEnableDownloaderService` is not enabled** because the host app already has network-client capability; the `Downloader.xpc` binary still ships inside the framework and still gets signed, but Sparkle won't route downloads through it at runtime.

The future `Rubien-MAS.entitlements` file will *not* include the mach-lookup keys. App Review flags them as suspicious for App Store apps; since the MAS build has no Sparkle, no exception is needed.

## File layout

### New Swift files

```
Sources/Rubien/
├── Services/
│   └── Updates/
│       ├── UpdateController.swift           ~120 lines — @Observable wrapper around SPUStandardUpdaterController
│       ├── UpdateUserDriverDelegate.swift   ~80 lines  — SPUStandardUserDriverDelegate to suppress scheduled-check UI
│       └── UpdateConstants.swift            ~20 lines  — feed URL, intervals, etc.
└── Views/
    └── Updates/
        ├── UpdateIndicator.swift            ~60 lines  — toolbar badge
        └── UpdateSettingsView.swift         ~130 lines — Settings → General → Updates pane
```

All five files wrapped top-to-bottom in `#if Sparkle` so they are literal no-ops when the trait is off.

**`UpdateController`** is an `@MainActor @Observable` class exposing:
- `canCheckForUpdates: Bool` (mirrors `SPUUpdater.canCheckForUpdates` via KVO)
- `updateReadyToInstall: Bool` (set by the delegate when a scheduled-check download completes)
- `pendingVersion: String?`
- `lastCheckDate: Date?`
- `automaticallyChecks: Bool` (passthrough to `SPUUpdater.automaticallyChecksForUpdates`)
- `automaticallyDownloads: Bool` (passthrough to `.automaticallyDownloadsUpdates`)
- `checkNow()`, `installAndRelaunch()` methods

The controller owns a `SPUStandardUpdaterController` and the `UpdateUserDriverDelegate` **as strong stored properties**. `SPUStandardUpdaterController` holds delegates as weak references; if the controller's delegate property is `weak`, our delegate gets deallocated immediately after init and the suppression breaks. Tests must cover the "delegate survives" lifecycle.

A protocol abstraction (`UpdaterProtocol`) over `SPUUpdater` lets `UpdateController` accept a test double in unit tests.

### Modified Swift files

| File | Change |
|---|---|
| `Sources/Rubien/RubienApp.swift` | Inside `#if Sparkle`: instantiate `UpdateController`, inject via `.environment(updateController)`. Add `Commands { ... }` block with the app-menu "Restart to Install Update" item. |
| `Sources/Rubien/Views/Settings/SettingsView.swift` (or wherever the settings root is) | Add `UpdateSettingsView()` tab under the General section, gated by `#if Sparkle`. |
| Main library window toolbar (location TBD by implementation plan) | Add `UpdateIndicator()` to the toolbar's trailing items. |
| `Sources/Rubien/Resources/Info.plist` | Stamped at build time by `build-app.sh` with the Sparkle keys (DMG flavor only). |
| `Sources/Rubien/Rubien.entitlements` | Add the two mach-lookup temporary-exception keys. |
| `Package.swift` | Bump `swift-tools-version` from `5.9` to `6.1`. Add `traits:` array. Add `Sparkle` package dependency. Add conditional product dependency + `swiftSettings` define to the `Rubien` target. |

### New + modified scripts and root files

| File | Change |
|---|---|
| `VERSION` | **NEW** at repo root. Single line, currently `0.1.0`. Hand-edited per release. |
| `BUILD` | **NEW** at repo root. Single line, monotonic integer, currently `1`. Bumped by `release.sh` (or by hand) before each release. |
| `scripts/build-app.sh` | Read `VERSION` and `BUILD`, stamp `Info.plist` via `plutil`. Add flavor arg (`dmg` default for v1, `mas` errors out). Inject Sparkle keys when flavor=dmg. Read `sparkle:minimumSystemVersion` from `Package.swift`'s deployment target. |
| `scripts/lib/codesign.sh` | **Rewrite.** Ordered five-step component signing inside `Sparkle.framework` (Installer.xpc → Downloader.xpc → Autoupdate → Updater.app → Sparkle.framework), then our own components. Use `--options runtime --timestamp`; never `--deep`. `Downloader.xpc` step adds `--preserve-metadata=entitlements`. |
| `scripts/release.sh` | **NEW** orchestrator. Steps: clean working tree check → bump `BUILD` → build → notarize → staple → static verification → `sign_update` → update appcast → `gh release create` → commit + push. |
| `scripts/lib/appcast.sh` | **NEW** helper, sourced by `release.sh`. Renders an `<item>` block with all required fields (`sparkle:version`, `sparkle:shortVersionString`, `sparkle:minimumSystemVersion`, `enclosure` with `url`, `sparkle:edSignature`, `length`, `type`). Prepends to existing `docs/appcast.xml`. |
| `docs/appcast.xml` | **NEW** RSS skeleton with empty `<channel>`. Bootstrapped once; `release.sh` mutates per release. |
| `docs/staging-appcast.xml` | **NEW** parallel appcast for end-to-end staging tests. |
| `docs/index.md` | **NEW** minimal GitHub Pages landing page linking to the latest GitHub Release. |
| `Docs/Release-Runbook.md` | **NEW** sibling to `Docs/Sync-Runbook.md`. One-time setup, per-release procedure, recovery scenarios, EdDSA rotation. |
| `CLAUDE.md` | Add a "Releases" section pointing at `Docs/Release-Runbook.md` and explaining the trait-based MAS gating. |

## Testing & verification

Three tiers, scaled to cost.

### Static verification (every release, automated in `release.sh`)

```bash
# Verify each component individually — --deep here is informational, not signing
codesign --verify --strict --verbose=2 build/Rubien.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
codesign --verify --strict --verbose=2 build/Rubien.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
codesign --verify --strict --verbose=2 build/Rubien.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
codesign --verify --strict --verbose=2 build/Rubien.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
codesign --verify --strict --verbose=2 build/Rubien.app/Contents/Frameworks/Sparkle.framework
codesign --verify --strict --verbose=2 build/Rubien.app

# Belt-and-suspenders deep verification after assembly, before DMG
codesign --verify --deep --strict --verbose=2 build/Rubien.app

# Notarization round-trip
xcrun stapler validate build/Rubien-0.1.0.dmg
spctl -a -t open --context context:primary-signature -vv build/Rubien-0.1.0.dmg

# EdDSA round-trip
./bin/sign_update --verify build/Rubien-0.1.0.dmg "<signature>" "<expected-public-key>"
```

`release.sh` fails loudly if any of these don't pass.

### Staging end-to-end (manual, before significant changes)

A separate `docs/staging-appcast.xml` and a debug-only `STAGING_FEED=1` build flag swap `SUFeedURL` to point at the staging path. Runbook:

1. Build a synthetic "0.1.0" baseline DMG (BUILD=1), notarize, install on a clean macOS Sequoia VM.
2. Build "0.1.1" DMG (BUILD=2), notarize, sign for Sparkle, add an `<item>` to `staging-appcast.xml` only.
3. On the test machine: wait for the scheduled check, or shorten `SUScheduledCheckInterval` to 60 seconds via a debug Info.plist.
4. Observe: Sparkle's standard window does not appear; toolbar badge appears; app-menu item enables; Settings status shows "Update 0.1.1 ready."
5. Click any of the three install surfaces. App quits, swaps, relaunches as 0.1.1 with no Gatekeeper dialog.
6. Confirm About panel shows 0.1.1.
7. **Second pass — user-initiated check:** click "Check Now" in Settings. Confirm Sparkle's standard "You're up to date" alert appears (no badge, no custom UI — by design).

Total runbook: ~15 minutes per pass. Critical to do this on a **clean Sequoia VM** the first time, since cached signature verification on the dev machine hides bugs that hit fresh users.

### Unit tests (cheap additions in `RubienTests`)

`UpdateController` state machine is testable with a protocol-mocked `SPUUpdater`. Tests cover:
- `updateReadyToInstall` flips on the delegate callback for scheduled checks
- `checkNow()` calls into the underlying updater (user-initiated path)
- Settings toggle round-trip (set → readback)
- `pendingVersion` populates from the appcast item
- **Delegate retention**: after `UpdateController` init returns, the delegate is still alive (regression test for the weak-reference foot-gun)

A protocol abstraction over `SPUUpdater` (~30 lines) makes these survive Sparkle version bumps.

### What's not tested

- Real Apple notarization round-trip in CI (slow, rate-limited, uses real credentials).
- Cross-version update paths (`0.1.0 → 0.3.0` skipping `0.2.0`) — Sparkle handles natively.
- Sparkle internals.

## Rollback & key compromise

### Bad release ships

Sparkle re-reads the appcast every check cycle (24h). Remove an `<item>` from `appcast.xml`, push, and within ~24h no new clients are offered that version.

```bash
$EDITOR docs/appcast.xml          # delete the <item> for the bad version
git commit -am "Pull v0.1.X from appcast (regression: …)"
git push                           # GitHub Pages updates within ~60s

gh release edit v0.1.X --prerelease=true         # demotes from "latest"
gh release edit v0.1.X --notes-file pulled.md    # explain the issue

# Fix forward
$EDITOR VERSION                    # bump to 0.1.X+1
$EDITOR BUILD                      # bump the build counter too
./scripts/release.sh
```

Limits:
- Clients who already downloaded the bad version may install it on next launch unless dismissed (Sparkle caches downloads).
- Already-installed users need the fix-forward release to recover. Sparkle has no "force downgrade" mechanism.

For genuine emergencies (data corruption, crash-on-launch), the fix-forward release can carry `<sparkle:criticalUpdate/>` on its `<item>` — Sparkle increases check frequency and surfaces the update more prominently. Use sparingly.

### EdDSA key backup discipline

Losing the EdDSA private key strands every existing installed Rubien client unless the dual-trust recovery path (next section) is available. Mandatory at key-generation time, before the first public release:

| Copy | Location | Format |
|---|---|---|
| Primary | macOS Login Keychain (where `bin/generate_keys` puts it) | Keychain item |
| Backup 1 | 1Password Personal vault | Exported `.key` file + generation-command stdout as a Secure Note |
| Backup 2 | Offline: encrypted USB drive | Same `.key` file |

The two backups must be in **independent failure domains** — 1Password + offline drive qualifies; two 1Password vaults does not.

### EdDSA key rotation (via Developer ID dual-trust)

Sparkle 2 does **not** support multi-key trust via a delegate. The actual recovery path is documented in Sparkle issue [#1501](https://github.com/sparkle-project/Sparkle/issues/1501) and relies on the fact that a release signed with both Apple Developer ID code-signing **and** EdDSA gives Sparkle two independent trust anchors. The rule:

> **Sparkle accepts a release where either the Developer ID cert OR the EdDSA key changes (but not both at the same time).**

What this means for compromise recovery:

- **EdDSA private key lost or leaked:** generate a new EdDSA keypair. Ship a release signed with the **new EdDSA key** but the **unchanged Developer ID cert**. Existing installed clients accept it because the cert chain still validates. All subsequent releases use the new EdDSA key. The new public key is embedded in the new release's `Info.plist`; clients updating to that release pick up the new public key for all future verifications.
- **Developer ID cert revoked or about to expire:** ship a release signed with the **same EdDSA key** but a **new Developer ID cert**. Existing clients accept it because the EdDSA signature still validates.
- **Both compromised simultaneously:** no in-band recovery. Users must manually re-download from GitHub Releases. Operationally, avoid this case by not storing both secrets in the same vault.

For v1, multi-key rotation is not pre-built — there is one key, no rotation history. The `UpdateController` wraps Sparkle, so future enhancements layer cleanly.

### Cert / notarization edge cases

| Scenario | Effect on installed apps | Recovery |
|---|---|---|
| Developer ID cert **expires** (~5 years) | None — existing apps continue to launch. Only new releases need re-signing. | Renew via Xcode → Settings → Accounts. |
| Developer ID cert **revoked** by Apple | All apps signed by that cert refuse to launch at next Gatekeeper check. | Appeal to Apple; new cert; re-release (single-anchor rotation path above). |
| Notarization ticket **revoked** for a specific release | That release shows "App could not be verified" on launch. | Pull from appcast; ship a fixed re-notarized release. |
| Apple Developer Program account **suspended** | All future releases blocked. | Appeal; rare and tied to ToS violation. |

Critical to internalize: **cert expiration does not break existing installs.** Apple's notarization ticket, once stapled, is independent of the cert's validity period.

## Effort estimate

| Task | Effort |
|---|---|
| Developer ID Application cert creation + 1Password backup | 30 min |
| EdDSA keys + Info.plist injection + entitlements | 1 hour |
| `Package.swift` migration to swift-tools-version 6.1 + trait + Sparkle dependency | 1 hour |
| `UpdateController` + delegate + SwiftUI bridge | 4-6 hours |
| Toolbar indicator + app-menu item + Settings pane | 3-4 hours |
| `scripts/lib/codesign.sh` rewrite (ordered five-step inside framework + ours) | 2-3 hours |
| `scripts/release.sh` orchestrator + `appcast.sh` helper with full schema | 3-4 hours |
| `docs/appcast.xml` bootstrap + GitHub Pages setup | 30 min |
| First end-to-end test release on clean Sequoia VM | 2-3 hours including debugging |
| `Docs/Release-Runbook.md` + `CLAUDE.md` update | 1 hour |

**Total: ~3 working days end-to-end.** Most risk is in `codesign.sh` (XPC signing order is fiddly and the new `Autoupdate` + `Updater.app` steps add surface area for typos) and the first notarization round-trip (always trips on something the first try). Apple Developer Program enrollment is already complete.

## References

Verified against current upstream documentation 2026-05-16:
- [Sparkle 2 sandboxing documentation](https://sparkle-project.org/documentation/sandboxing/) — verbatim signing recipe with `--preserve-metadata=entitlements` on Downloader.xpc
- [Sparkle 2 main documentation](https://sparkle-project.org/documentation/)
- [Sparkle 2 programmatic setup (SwiftUI)](https://sparkle-project.org/documentation/programmatic-setup/)
- [Sparkle on Swift Package Index](https://swiftpackageindex.com/sparkle-project/Sparkle) — 2.7.3 current
- [Sparkle issue #1501: EdDSA key rotation](https://github.com/sparkle-project/Sparkle/issues/1501) — Developer-ID + EdDSA dual-trust rotation mechanism
- [Steinberger: Code Signing and Notarization — Sparkle and Tears (2025)](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears) — the `--deep` and entitlement gotchas
- [Apple: Gatekeeper and runtime protection in macOS](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)
- [Apple Developer: Updates to runtime protection in macOS Sequoia](https://developer.apple.com/news/?id=saqachfa) — Control-click bypass removal
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — notarytool keychain profiles, `--wait` flag
- [SE-0450: SwiftPM Package Traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)
- [SwiftPM Package Traits documentation](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/packagetraits/)
- [Swift 6.1 release notes](https://www.swift.org/blog/swift-6.1-released/) — Traits API availability

## Codex review 2026-05-16 — findings folded in

Pre-commit independent review by Codex surfaced six items now reflected in this revision:

1. **Signing sequence completion** — added `Autoupdate` and `Updater.app` between `Downloader.xpc` and `Sparkle.framework` (folded into "Code signing" section).
2. **`--preserve-metadata=entitlements` for Downloader.xpc** — explicit per Sparkle docs (folded into signing recipe).
3. **EdDSA rotation mechanism corrected** — was incorrectly attributed to a fictitious delegate API; replaced with the actual Developer-ID + EdDSA dual-trust path documented in Sparkle issue #1501.
4. **swift-tools-version migration** — called out as an explicit prerequisite in its own section (Package.swift was 5.9; traits require 6.0+).
5. **Build counter source** — switched from `git rev-list --count HEAD` to a plain `BUILD` file at repo root, to survive history rewrites.
6. **Appcast schema enumeration + justification** — added explicit schema block with required fields, plus a one-paragraph justification for manual editing vs `generate_appcast`.

Plus concerns folded in:
- User-initiated check intentionally not suppressed (asymmetry documented up front).
- Downloader XPC service signed but not enabled at runtime (host has network entitlement already).
- `SUEnableSystemProfiling` explicitly stays off (no anonymous telemetry).
- Appcast-unreachable UI behavior defined for both scheduled and user-initiated paths.
- `SUAutomaticallyUpdate` authorization-prompt edge case documented.
- Delegate retention noted as a known foot-gun + covered by unit test.
- Belt-and-suspenders `codesign --deep --verify` check added before DMG assembly.

Three Codex findings (SPM trait syntax "bare identifiers" in three places, blockers 3-5) were quote-back artifacts and did not require code changes — the spec's trait declarations use string literals throughout per SE-0450.
