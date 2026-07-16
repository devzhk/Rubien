# Reader Tabs Redesign: Clip + Original Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current Clipped/Live tab pair (both of which display reader-extracted HTML — Clipped from cache, Live re-extracted now) with a Clip tab (refreshable cached extraction) + an Original tab (raw page in WKWebView, no Defuddle injection). Eliminates the "user must click Live to see fresh content" trap by collapsing the two extraction-style tabs into one with an explicit refresh button.

**Architecture:** Pure UX/state-machine refactor in `WebReaderView.swift`. The `WebReaderDisplayMode` enum changes from `clippedMarkdown | liveReadable` to `clip | original`. The Clip tab keeps the existing extracted-HTML render path; a new toolbar refresh button triggers re-extraction (the current `setDisplayMode(.liveReadable)` machinery, plumbed through to stay in `.clip` mode after success). The Original tab takes a new code path that loads the URL in WKWebView with NO Defuddle injection, NO annotation hooks. External `<a>` clicks from Clip mode open in the system default browser.

**Tech Stack:** SwiftUI + WKWebView (`WKNavigationDelegate` `decidePolicyFor` for link-click interception), `NSWorkspace.shared.open(_:)` for opening links externally. No new dependencies.

**Scope boundaries (NOT in this plan):**
- **Annotations on Original tab.** Out of scope per user decision — Original is read-only browser view. Raw pages lack stable selectors for annotation anchors.
- **Auto-refresh when content is stale-by-age** (e.g. "older than N days"). Out of scope — only auto-refresh when `webContent` is empty.
- **Floating-window WKWebView for link click-throughs.** Links open in system browser; no in-app browser experience.
- **Stale `webContent` migration.** Existing references keep their `webContent` as-is. Refresh button is opt-in.
- **Auto-extract-on-add improvements.** The WebImportView clip flow is separately responsible for the initial extraction.

---

### File Structure

All changes in one file:
- **Modify:** `Sources/Rubien/Views/WebReaderView.swift`
  - Enum rename + raw-string update (line 14-19)
  - State-machine update in `setDisplayMode` (line 223-247)
  - `applyReadableExtractionResult` post-success: stay in `.clip` instead of remaining in `.liveReadable`
  - New `refreshClipContent()` viewmodel method
  - Toolbar refresh button (line 1578-1604)
  - Coordinator `updateNSView` branches: `.clip` keeps existing path; `.original` new path
  - `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)`: in `.clip` mode, intercept link-navigation to `NSWorkspace`; in `.original` mode, allow in-WebView navigation
- **Touch (small):** `Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift`
  - No behavioral change. Just possibly a small comment update if the "Live" terminology in `eyebrowText` is hardcoded.

---

### Task 1: Rename enum + update labels

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift:14-19`

- [ ] **Step 1: Update the enum**

```swift
enum WebReaderDisplayMode: String, CaseIterable {
    /// Show the reference's clipped, extracted content (with refresh).
    case clip = "Clip"
    /// Load the original page URL in WKWebView with no extraction.
    case original = "Original"
}
```

- [ ] **Step 2: Build + verify Swift compile**

```bash
swift build --target Rubien 2>&1 | tail -3
```

Expected: compilation errors at every reference to `.clippedMarkdown` and `.liveReadable` (~50 sites in WebReaderView.swift). These get fixed in Task 2.

---

### Task 2: Mass-rename references inside WebReaderView.swift

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift` (~50 sites)

- [ ] **Step 1: Find all references**

```bash
grep -n 'clippedMarkdown\|liveReadable\|isLiveReadableBusy\|liveReadableUserMessage\|liveReadableSafetyTask\|shouldLoadOriginalURLForReadable\|resetLiveReadableNavigation' Sources/Rubien/Views/WebReaderView.swift
```

- [ ] **Step 2: Apply the renames**

| Old | New |
|---|---|
| `.clippedMarkdown` | `.clip` |
| `.liveReadable` | `.original` |
| `isLiveReadableBusy` | `isExtracting` (renamed — semantically it's now "is refresh in progress", not "is live mode active") |
| `liveReadableUserMessage` | `extractionUserMessage` |
| `liveReadableSafetyTask` | `extractionSafetyTask` |
| `shouldLoadOriginalURLForReadable` | `shouldLoadOriginalURLForExtraction` |
| `resetLiveReadableNavigation` | `resetExtractionNavigation` |
| `cancelLiveReadableSafetyTimeout()` | `cancelExtractionSafetyTimeout()` |
| `scheduleLiveReadableSafetyTimeout()` | `scheduleExtractionSafetyTimeout()` |
| `isLiveReadableBusyContext` | `isExtractingContext` |

Use Edit's `replace_all: true` for each. Do NOT bulk-replace across the whole repo — keep this scoped to `WebReaderView.swift`. Verify via repeated grep that no `liveReadable` references remain in this file.

- [ ] **Step 2b: Update sites where the semantic check changed**

Pure rename is NOT enough at these sites — the meaning shifted. Audit and update:

1. **`isExtractingContext` closure (currently line 1850-1854)**: was `displayMode == .liveReadable && isLiveReadableBusy`. Should become `displayMode == .clip && isExtracting` (refresh runs in Clip mode, not Original).
2. **`scheduleExtractionSafetyTimeout` guard (currently line 255)**: was `displayMode == .liveReadable, isLiveReadableBusy`. Should become `displayMode == .clip, isExtracting`.
3. **Failure-handler guards (currently line 1937, 1947)**: same as above — `displayMode == .clip, isExtracting`.

- [ ] **Step 2c: Rename `isLiveReadableBusyContext` across the manager API and ALL setters**

`isLiveReadableBusyContext` is a property on `ReaderExtractionManager` (`Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift:20`) set from TWO files: `WebReaderView.swift:1850` and `ClipperWebMetadataExtractor.swift:72`. Rename the API and update both setters so the name stays consistent across the codebase:

| File | Line | Edit |
|---|---|---|
| `Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift` | 20 | `var isLiveReadableBusyContext: (() -> Bool)?` → `var isExtractionBusyContext: (() -> Bool)?` |
| `Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift` | 224, 229 | `self.isLiveReadableBusyContext?()` → `self.isExtractionBusyContext?()` |
| `Sources/Rubien/Views/WebReaderView.swift` | 1850 | `extractionManager.isLiveReadableBusyContext = ...` → `extractionManager.isExtractionBusyContext = ...` AND the closure body becomes `vm.displayMode == .clip && vm.isExtracting` |
| `Sources/Rubien/Services/ClipperWebMetadataExtractor.swift` | 72 | `extractionManager.isLiveReadableBusyContext = ...` — closure body in this file should NOT be touched (it has its own semantics for the import flow); just rename the property |

After this rename, `isExtractionBusyContext` reads correctly in both contexts (clip refresh AND import-time extraction).

- [ ] **Step 3: Build, expect compile errors only at semantic-meaning sites**

```bash
swift build --target Rubien 2>&1 | tail -5
```

Some sites need behavioral fix not just rename (e.g. `displayMode == .liveReadable` checks that meant "is extraction in progress" should become `isExtracting`). These are addressed in Tasks 3-5.

---

### Task 3: Rewrite `setDisplayMode` for the new semantics

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift:223-247`

- [ ] **Step 1: New `setDisplayMode` implementation**

```swift
func setDisplayMode(_ mode: WebReaderDisplayMode) {
    guard mode != displayMode else { return }
    extractionUserMessage = nil
    displayMode = mode
    switch mode {
    case .clip:
        // Cancel any in-flight Original-page load. The Coordinator's
        // updateNSView will reload the clipped HTML.
        cancelExtractionSafetyTimeout()
        shouldLoadOriginalURLForExtraction = false
        isExtracting = false
        resetExtractionNavigation?()
        renderContent()
    case .original:
        // Validate URL; switch back to .clip if missing.
        let u = reference.resolvedWebReaderURLString() ?? ""
        guard !u.isEmpty, URL(string: u) != nil else {
            extractionUserMessage = String(localized: "No valid URL available for the original page.", bundle: .module)
            displayMode = .clip
            return
        }
        // Cancel any in-flight refresh extraction. The Coordinator's
        // awaitingReadableExtraction must be cleared too — otherwise
        // when the Original-tab URL load finishes, didFinish will see
        // the stale flag and inject Defuddle into the live page,
        // overwriting the user's clipped content. resetExtractionNavigation
        // clears that flag AND calls stopLoading() on the WKWebView.
        cancelExtractionSafetyTimeout()
        shouldLoadOriginalURLForExtraction = false
        isExtracting = false
        resetExtractionNavigation?()
    }
}
```

Key changes:
- `.original` mode no longer triggers extraction. Extraction is now a dedicated user action via the refresh button (Task 4).
- BOTH branches call `resetExtractionNavigation?()` — defends against the user switching tabs mid-refresh (clears `awaitingReadableExtraction` so the in-flight WK navigation doesn't inject Defuddle when it finishes).

- [ ] **Step 2: Build + verify**

```bash
swift build --target Rubien 2>&1 | tail -3
```

Expected: clean build of `setDisplayMode`. Errors may still remain in the Coordinator's `updateNSView` (addressed in Task 5).

---

### Task 4: Add `refreshClipContent()` method + toolbar button + auto-extract-on-empty

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift` (viewmodel + toolbar)

- [ ] **Step 1: New viewmodel method — triggers extraction from .clip mode**

Add to `WebReaderViewModel`:

```swift
/// Trigger a fresh extraction of the source URL, replacing reference.webContent.
/// Caller stays in .clip mode; updateNSView will swap to the new content on success.
func refreshClipContent() {
    guard displayMode == .clip else { return }
    guard !isExtracting else { return }
    let u = reference.resolvedWebReaderURLString() ?? ""
    guard !u.isEmpty, URL(string: u) != nil else {
        extractionUserMessage = String(localized: "No valid URL available to refresh from.", bundle: .module)
        return
    }
    shouldLoadOriginalURLForExtraction = true
    isExtracting = true
    scheduleExtractionSafetyTimeout()
    let host = URL(string: u)?.host ?? ""
    onlineReadableLog.notice("Refreshing clip content host=\(host, privacy: .public) using bundled ClipperDefuddle.js")
}
```

Key: this is the ONLY entry point for extraction. `setDisplayMode(.original)` no longer kicks off extraction.

- [ ] **Step 2: Add an `auto-extract on empty webContent` trigger**

In `WebReaderViewModel.init`, place this RIGHT AFTER the existing fresh-fetch block (currently `Sources/Rubien/Views/WebReaderView.swift:73-95`, which already re-fetches `webContent` from disk and sets `self.reference.webContent = fresh`). Use the existing `decodedWebContent` helper or check the `String?` value directly — `Reference.webContent` is `String?`, not `Data` (see `Sources/RubienCore/Models/Reference.swift:173`):

```swift
// After the existing fresh-fetch block (line ~95 in current source):
let hasContent = !(reference.webContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
if !hasContent && reference.resolvedWebReaderURLString() != nil {
    Task { @MainActor [weak self] in
        // Defer one tick so SwiftUI's initial render completes first
        // (the spinner needs the toolbar mounted to be visible).
        self?.refreshClipContent()
    }
}
```

Existing `canLiveRead` branch at line 88 already sets `displayMode = .liveReadable` for the auto-trigger case — that needs to be removed (the new auto-trigger handles it without changing displayMode away from `.clip`).

- [ ] **Step 3: Toolbar refresh button**

Update the toolbar block (currently line 1578-1604):

```swift
.toolbar {
    ToolbarItemGroup(placement: .automatic) {
        if viewModel.allowsDisplayModeSwitching {
            Picker(String(localized: "Reading mode", bundle: .module), selection: Binding(
                get: { viewModel.displayMode },
                set: { viewModel.setDisplayMode($0) }
            )) {
                ForEach(WebReaderDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
        }

        // Refresh button — only visible in Clip mode
        if viewModel.displayMode == .clip {
            Button {
                viewModel.refreshClipContent()
            } label: {
                if viewModel.isExtracting {
                    ProgressView().controlSize(.small)
                } else {
                    Label(String(localized: "Refresh", bundle: .module), systemImage: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isExtracting || viewModel.reference.resolvedWebReaderURLString() == nil)
            .help(String(localized: "Re-extract from the source URL", bundle: .module))
        }

        fontControls
        widthControls
    }
    // ... primaryAction group unchanged
}
```

- [ ] **Step 4: Verify on-success behavior stays in .clip mode**

Currently `applyReadableExtractionResult` (line 280-313) leaves `displayMode == .liveReadable`. After this refactor, refresh keeps `displayMode == .clip` already (we set it before triggering). Verify by reading `applyReadableExtractionResult` and removing any `displayMode = .liveReadable` assignments if present (there shouldn't be — but check).

- [ ] **Step 5: Build**

```bash
swift build --target Rubien 2>&1 | tail -3
```

Expected: clean build.

---

### Task 5: Coordinator's `updateNSView` — new `.original` path (no Defuddle injection)

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift:1785-1820` (the `updateNSView` body)

Currently `updateNSView` has two branches:
1. If `shouldLoadOriginalURLForReadable && displayMode == .liveReadable` → load URL, set `awaitingReadableExtraction = true` (triggers Defuddle in didFinish).
2. Else → render extracted HTML via `loadHTMLString`.

New logic needs THREE branches:
1. If `shouldLoadOriginalURLForExtraction && displayMode == .clip` (refresh in progress) → load URL, set `awaitingReadableExtraction = true` (triggers Defuddle in didFinish), result populates `reference.webContent` and re-renders.
2. Else if `displayMode == .original` → load URL, do NOT set `awaitingReadableExtraction` (no Defuddle).
3. Else → render extracted HTML via `loadHTMLString` (clipped content).

- [ ] **Step 1: Add explicit `currentlyLoadedMode` to Coordinator**

`nsView.url` isn't a reliable signal for "what mode is currently rendered" — the clipped HTML's `baseURL` IS the source URL (see line 1812, 1829-1833), so `nsView.url == sourceURL` is true for BOTH the clipped render AND the original-page load. Add explicit state:

```swift
// In the Coordinator (around line 1841, near `awaitingReadableExtraction`):
var currentlyLoadedMode: WebReaderDisplayMode? = nil  // nil = nothing loaded yet
```

Update at every load site (Cases 1, 2, 4 below).

- [ ] **Step 2: Rewrite the `updateNSView` switch**

```swift
func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.bind(to: viewModel)

    // Case 1: Refresh-triggered URL load (extraction expected)
    if viewModel.shouldLoadOriginalURLForExtraction,
       viewModel.displayMode == .clip,
       let urlString = viewModel.reference.resolvedWebReaderURLString(),
       let pageURL = URL(string: urlString) {
        viewModel.acknowledgeOriginalURLLoadStarted()
        context.coordinator.extractionManager.resetForNewNavigation()
        context.coordinator.awaitingReadableExtraction = true
        context.coordinator.lastLoadedHTML = ""
        context.coordinator.currentlyLoadedMode = nil  // pending — will be .clip when extraction completes
        nsView.stopLoading()
        nsView.load(URLRequest(url: pageURL))
        return
    }

    // Case 2: Original-tab URL load (NO extraction)
    if viewModel.displayMode == .original,
       let urlString = viewModel.reference.resolvedWebReaderURLString(),
       let pageURL = URL(string: urlString) {
        // Clear extraction state FIRST — otherwise a stale flag from a
        // prior refresh could cause didFinish to inject Defuddle into
        // the Original-page load.
        context.coordinator.awaitingReadableExtraction = false
        // Skip the load only if the SAME mode is already displayed.
        // URL-equality alone is unreliable because clipped HTML uses
        // sourceURL as baseURL, so nsView.url == sourceURL for BOTH
        // clipped and original renders.
        if context.coordinator.currentlyLoadedMode == .original,
           nsView.url?.absoluteString == urlString {
            return
        }
        context.coordinator.extractionManager.resetForNewNavigation()
        context.coordinator.lastLoadedHTML = ""
        context.coordinator.currentlyLoadedMode = .original
        nsView.stopLoading()
        nsView.load(URLRequest(url: pageURL))
        return
    }

    // Case 3: Extraction in progress, don't overwrite the loading WKWebView
    if viewModel.displayMode == .clip,
       viewModel.isExtracting || context.coordinator.awaitingReadableExtraction {
        return
    }

    // Case 4: Render the cached clipped HTML
    if context.coordinator.currentlyLoadedMode != .clip ||
       context.coordinator.lastLoadedHTML != viewModel.renderedHTML {
        context.coordinator.awaitingReadableExtraction = false
        context.coordinator.lastLoadedHTML = viewModel.renderedHTML
        context.coordinator.currentlyLoadedMode = .clip
        context.coordinator.invalidateAnnotationsPushCache()
        nsView.loadHTMLString(viewModel.renderedHTML, baseURL: URL(string: referenceBaseURL))
    } else {
        context.coordinator.pushAppearance()
    }
}
```

When extraction succeeds and `applyReadableExtractionResult` updates `renderedHTML`, `updateNSView` re-fires with `currentlyLoadedMode == nil` (set in Case 1 above) — Case 4 triggers and sets it to `.clip`.

- [ ] **Step 2: Build**

```bash
swift build --target Rubien 2>&1 | tail -3
```

Expected: clean build.

---

### Task 6: Gate annotation push on `.clip` mode (multiple callsites)

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift` — `didFinish` (line 1913) AND `pushAnnotations` (line 2066) AND the `refreshAnnotationsInView` callback wiring (line 1908)

Codex Pass 1 finding #3: annotations get pushed by THREE independent paths, not just `didFinish`:

1. **`didFinish` after URL load** (line 1913-1924)
2. **`refreshAnnotationsInView` callback fired by the annotation observer** (line 432-435, bound at line 1908-1910) — fires whenever the annotation array changes, regardless of displayMode
3. **Direct `pushAnnotations` calls** elsewhere in the Coordinator

In Original mode, the WKWebView is showing a raw web page that has no `window.RubienReader` API — pushes would silently fail OR fire JS-evaluation errors. Gate at the SOURCE (`pushAnnotations` itself) to cover all callers.

- [ ] **Step 1: Update `didFinish`**

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if awaitingReadableExtraction {
        awaitingReadableExtraction = false
        let pageURL = webView.url?.absoluteString ?? "(nil)"
        onlineReadableLog.notice("WK didFinish url=\(pageURL, privacy: .public) — about to inject Defuddle extraction")
        extractionManager.runOnlineArticleExtraction(from: webView)
        return
    }
    // Annotations and appearance hooks only apply to the clipped HTML render;
    // Original mode shows a raw web page without window.RubienReader.
    let vm = parent.viewModel
    if vm.displayMode == .original {
        WebReaderContentView.applyElegantScrollers(to: webView)
        return
    }
    pushAppearance()
    pushAnnotations()
    WebReaderContentView.applyElegantScrollers(to: webView)
}
```

- [ ] **Step 2: Add early-return guard inside `pushAnnotations` itself**

Find `pushAnnotations` (currently around line 2066) and add:

```swift
func pushAnnotations() {
    // Original mode shows a raw web page without window.RubienReader —
    // pushing would evaluate `undefined.setAnnotations(...)` and throw.
    guard parent.viewModel.displayMode == .clip else { return }
    // ...rest of existing implementation
}
```

This protects ALL callers (didFinish, refreshAnnotationsInView callback, anywhere else) in one place.

- [ ] **Step 3: Same guard on `pushAppearance` if it touches `window.RubienReader`**

Inspect `pushAppearance` and gate similarly if it evaluates reader-only JS.

- [ ] **Step 4: Build**

```bash
swift build --target Rubien 2>&1 | tail -3
```

---

### Task 7: Link-click interception (Clip mode → system browser)

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift` (Coordinator extension — `WKNavigationDelegate`)

Currently the Coordinator likely doesn't intercept link clicks (or does — verify). For Clip mode, external links should open in the system default browser (`NSWorkspace.shared.open`). For Original mode, in-WebView navigation is fine.

- [ ] **Step 1: Verify whether `decidePolicyFor` is already implemented**

```bash
grep -n 'decidePolicyFor\|WKNavigationActionPolicy' Sources/Rubien/Views/WebReaderView.swift
```

If not implemented, add it. If already implemented for some other purpose, modify in place.

- [ ] **Step 2: Add/modify `decidePolicyFor` to route Clip-mode external link clicks to system browser**

Critical: clipped HTML is loaded with the source URL as `baseURL` (line 1812). So anchor links like `#section-2` resolve to `https://yumoxu.notion.site/...#section-2` — fully-qualified http(s) URLs. A naive `url.scheme == "https"` check would intercept these and open the page in a browser instead of scrolling.

Use explicit scheme/host/path comparison. `URL.path` is percent-decoded, so `%20` vs space is normalized automatically. `URLComponents.url` equality is fragile (sensitive to encoding form), and `URL.standardized` doesn't normalize trailing slashes — explicit component comparison is the reliable path.

```swift
func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let vm = parent.viewModel
    guard vm.displayMode == .clip,
          navigationAction.navigationType == .linkActivated,
          let url = navigationAction.request.url,
          url.scheme == "http" || url.scheme == "https" else {
        decisionHandler(.allow)
        return
    }
    // Detect same-document fragment navigation (anchor links). These should
    // scroll within the WKWebView, NOT open in the system browser.
    // Compare scheme + host + path explicitly — URLComponents/URL equality
    // is sensitive to percent-encoding differences (%20 vs +) and trailing
    // slashes that don't matter semantically. URL.path is percent-decoded,
    // so the comparison is normalized.
    if url.fragment != nil,
       let currentURL = webView.url,
       url.scheme == currentURL.scheme,
       url.host?.lowercased() == currentURL.host?.lowercased(),
       url.port == currentURL.port,
       url.path == currentURL.path,
       url.query == currentURL.query {
        decisionHandler(.allow)
        return
    }
    NSWorkspace.shared.open(url)
    decisionHandler(.cancel)
}
```

Trailing-slash normalization (`/foo` vs `/foo/`): URL resolution against a baseURL preserves the baseURL's trailing-slash style, so in practice `currentURL.path` and resolved-anchor `url.path` will agree. If real-world telemetry shows mismatches, fold in a `String(path.drop(while: { $0 == "/" }))`-style normalization as a follow-up.

- [ ] **Step 3: Build**

```bash
swift build --target Rubien 2>&1 | tail -3
```

---

### Task 8: Add "Last refreshed" timestamp display (optional polish)

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift` (toolbar or eyebrow area)

Show "Updated · just now" / "Updated 3 days ago" near the refresh button or at the top of content.

- [ ] **Step 1: Surface the timestamp**

Use `reference.dateModified` (already in the schema). Convert via `RelativeDateTimeFormatter`:

```swift
private static let updatedFmt: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
}()

var lastUpdatedText: String {
    let rel = Self.updatedFmt.localizedString(for: reference.dateModified, relativeTo: Date())
    return String(format: String(localized: "Updated %@", bundle: .module), rel)
}
```

- [ ] **Step 2: Place in toolbar next to refresh button (or hover-tooltip)**

```swift
if viewModel.displayMode == .clip, viewModel.reference.webContent != nil {
    Text(viewModel.lastUpdatedText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(String(localized: "Time since the clip was last extracted", bundle: .module))
}
```

- [ ] **Step 3: Build**

If you'd rather defer this polish, mark Task 8 as a follow-up and skip — the core UX redesign is complete after Task 7.

---

### Task 9: Smoke test in UI

**Files:** (none — manual)

- [ ] **Step 1: Launch + verify Clip-only behavior on existing reference**

```bash
swift run Rubien
```

Open an existing clipped reference. Expected:
- Lands in Clip mode showing cached content
- Refresh button visible in toolbar
- Original button visible in mode picker
- No automatic extraction (cached content displays immediately)

- [ ] **Step 2: Click refresh in Clip mode**

Expected:
- Refresh button shows spinner
- Background extraction runs (use Console.app filter "Rubien" to confirm)
- On success: content updates, button returns to icon state
- `dateModified` updates (visible if Task 8 done)

- [ ] **Step 3: Switch to Original tab**

Expected:
- Loads the URL in WKWebView with full original styling
- No extraction triggered (no `rubien_defuddle_extract_start` in Console)
- Annotations are NOT visible (raw page)
- In-page navigation works (clicking links navigates within WKWebView)

- [ ] **Step 4: Switch back to Clip**

Expected:
- Re-displays the cached (possibly just-refreshed) content
- Annotations re-appear
- Refresh button visible again

- [ ] **Step 5: Click an external link in Clip mode**

Expected:
- Opens in system default browser
- Reader view doesn't navigate away

- [ ] **Step 6: Add a fresh URL (empty webContent path)**

Use Add Reference / Web Clip with a fresh URL that hasn't been clipped before. Expected:
- Opens reader → Clip mode is selected
- Refresh button auto-fires once (spinner appears immediately)
- Content populates after extraction completes

- [ ] **Step 7: Test on a non-Notion site**

Re-clip an arxiv abstract or similar. Expected:
- No 5s discriminator delay (already Notion-gated)
- Refresh completes quickly
- Content renders correctly

---

### Task 10: Send to Codex for review

**Files:** (no edits — review)

The change touches the state machine + view hierarchy in one of the most critical user-facing files. Two Codex passes warranted:

- **Pass 1 (broad):** Focus on:
  1. State-machine correctness post-patch — does the `.original` branch's `resetExtractionNavigation?()` correctly cancel any in-flight refresh?
  2. `updateNSView` race conditions — verify the explicit `currentlyLoadedMode` tracking eliminates the URL-equality-with-baseURL ambiguity.
  3. Memory leak risk in the refresh button's Task closure — is `[weak self]` correctly captured?
  4. `decidePolicyFor` same-document detection — does the `URLComponents` fragment-strip comparison handle edge cases (URL with query string ?a=1#section vs ?a=1, IDN hosts, percent-encoding)?
  5. Auto-extract-on-empty — does the trigger fire only once even with SwiftUI re-renders?
  6. `pushAnnotations` guard at source — any caller that bypasses the guard via direct `evaluateJavaScript`?
  7. `isExtractingContext` and other semantic-renamed sites — did Step 2b's audit miss any?
  8. `ClipperWebMetadataExtractor.swift:72-73` collision — confirmed no shared-instance issue?

- **Pass 2 (if Pass 1 finds anything):** Verify patches.

---

### Task 11: Commit

**Files:** (commits the work)

- [ ] **Step 1: Inspect staged diff**

```bash
git status --short
```

Expected modifications:
- `Sources/Rubien/Views/WebReaderView.swift` (~85% of changes)
- `Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift` (3 lines — rename `isLiveReadableBusyContext` to `isExtractionBusyContext` in the property declaration + 2 internal callsites)
- `Sources/Rubien/Services/ClipperWebMetadataExtractor.swift` (1 line — same rename at the setter)

Expected new files:
- `Docs/plans/2026-05-23-reader-tabs-clip-and-original.md` (this plan)

NOT expected:
- Changes to the database schema or `Reference` model
- Changes to `ClipperDefuddle.js` (the bundle is reused as-is)
- Changes to the extraction pipeline itself (only the busy-context API name changes; behavior stays)

- [ ] **Step 2: Stage explicitly and commit**

```bash
git add Sources/Rubien/Views/WebReaderView.swift \
        Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift \
        Sources/Rubien/Services/ClipperWebMetadataExtractor.swift \
        Docs/plans/2026-05-23-reader-tabs-clip-and-original.md

git commit -m "$(cat <<'EOF'
reader: collapse Clipped/Live tabs into Clip+Refresh, add Original tab

The previous Clipped/Live tab pair was confusing: both displayed reader-
extracted HTML, just from different points in time. Live was effectively
a "re-extract now" button disguised as a tab — and the Clip tab only
got fresh content when the user happened to switch to Live first.

New UX:
- Clip tab (default): displays cached extracted HTML with a Refresh
  button in the toolbar. Auto-extracts once on open if webContent is
  empty (fresh-add flow). External link clicks open in system browser.
- Original tab: loads the source URL directly in WKWebView with NO
  Defuddle injection. Real page rendering, no annotations. In-page
  navigation works as in a browser.

Implementation: single-file refactor in WebReaderView.swift. Enum renamed
(clippedMarkdown → clip, liveReadable → original). State-machine in
setDisplayMode no longer kicks off extraction — that's now a dedicated
refreshClipContent() viewmodel method called by the toolbar button or
the auto-extract-on-empty trigger. Coordinator's updateNSView grows a
third branch for .original (load URL, skip extraction). decidePolicyFor
intercepts Clip-mode link clicks to NSWorkspace.shared.open.

Out of scope (follow-ups): annotations on Original tab (raw pages
lack stable selectors); staleness-based auto-refresh; floating-window
in-app browser for click-throughs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

**Spec coverage:** Plan addresses every decision the user locked in: (a) merge Clipped+Live into Clip+Refresh ✓, (b) add Original tab as raw browser view ✓, (c) external link clicks → system browser ✓, (d) annotations off on Original ✓, (e) auto-refresh only when webContent empty ✓.

**Placeholder scan:** Task 2's table is a concrete rename map. Task 3-7 show full code blocks. Task 4 Step 2 has an "if existing init pattern uses lazy/late binding, adjust accordingly" caveat — this is the only place where the plan can't fully specify ahead of reading the current code; the executor will need to find the binding site.

**Type consistency:** Enum cases `.clip` / `.original` used consistently across all tasks. `refreshClipContent()` signature is `() -> Void` everywhere. `isExtracting` is `Bool`.

**Known limitations / follow-ups not in this plan:**
- **Annotations on Original tab.** Out of scope per user decision. Future work would need URL-fragment-based anchor storage (page might re-paginate between visits) + JS injection on Original page for selection capture.
- **Stale-by-age auto-refresh.** Skipped per user choice. If desired later: check `Date().timeIntervalSince(reference.dateModified) > threshold` in the auto-extract-on-empty trigger.
- **Floating in-app browser** for link click-throughs. Skipped per user choice. Future option: a third tab "Browser" that allows arbitrary in-app navigation.
- **WKWebView session sharing.** Original tab uses the same WKWebView instance as Clip (the Coordinator's `webView`). If the URL load races against a pending refresh-extraction, state could get tangled. Codex Pass 1 area #2 is meant to catch this.
- **eyebrow text in ReaderExtractionManager.swift.** The current code sets `eyebrowText: "Live · Defuddle"` and `"Live"` for Readability — semantically wrong now that we're not in "Live" mode. Either update those strings or strip the eyebrow concept entirely.
- **WebImportView clip flow.** Initial-add extraction lives there separately. Out of scope; that path is independent of the reader-view display modes.
