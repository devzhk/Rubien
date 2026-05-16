# Paper landing-page URL resolver Implementation Plan

**Version:** v3 — incorporates second-pass Codex plan-review feedback

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Add-by-Identifier paste box in Rubien to recognize paper landing-page URLs from OpenReview, ACL Anthology, CVF Open Access, NeurIPS, PMLR, IEEE Xplore, ACM DL, Nature, Springer, and ScienceDirect, producing authoritative `Reference` records with optional PDF auto-download.

**Architecture:** Two new files in `RubienCore/Services/` — `PaperURLResolver.swift` (orchestrator) and `CitationMetaScraper.swift` (generic `<meta name="citation_*">` HTML parser). Both ship together because `CitationMetaScraper` references `KnownPaperHost` and a shared `fetchHTML` helper defined in `PaperURLResolver.swift`. Pure `URLSession` + HTML parsing; works in `rubien-cli` too. The new `MetadataFetcher.Identifier.paperURL` case routes through `PaperURLResolver.resolve`, which may re-fetch via CrossRef when a DOI is found, then merges using existing `MetadataResolution.mergeReference`. CVF gets a separate BibTeX adapter (inline in `PaperURLResolver.swift`) since CVF pages don't expose `citation_*` meta. Optional PDF auto-download threads a `pdfURLOverride: String?` through a new `ManualEntryOutcome` wrapper and the existing callback chain — no `Reference` field changes, no `MetadataResolutionResult` enum shape changes, no migrations.

**Tech Stack:** Swift 6 (strict concurrency, Sendable, region-based isolation), GRDB 7.10, macOS 15 deployment, Foundation `URLSession`, `XCTest` for tests. Spec lives at `Docs/superpowers/specs/2026-05-16-paper-url-resolver-design.md` — read it first if you haven't.

**Pre-flight check before starting:**

```bash
cd /Users/hzzheng/CodeHub/Rubien
xcode-select -p              # must point to /Applications/Xcode.app/Contents/Developer (not CLT)
swift build                  # must succeed before any task
git status                   # must be clean
```

If `swift build` fails on a stale `.build/checkouts`, run `rm -rf .build .swiftpm && swift package resolve`.

---

## File Structure

**New files:**

- `Sources/RubienCore/Services/PaperURLResolver.swift` — orchestrator: `KnownPaperHost` enum, URL canonicalization, PDF→landing rewrite, dispatch, CVF BibTeX adapter, shared `fetchHTML` helper.
- `Sources/RubienCore/Services/CitationMetaScraper.swift` — pure HTML `<meta name="citation_*">` parser + `fetch(url:session:)` wrapper.
- `Tests/RubienCoreTests/Fixtures/CitationMeta/*.html` — captured HTML fixtures for the 9 citation-meta hosts + paywall + malformed cases.
- `Tests/RubienCoreTests/Fixtures/CitationMeta/FIXTURE-NOTES.md` — refresh procedure.
- `Tests/RubienCoreTests/BibTeXImporterCVFTests.swift` — locks BibTeX behavior on CVF blocks.
- `Tests/RubienCoreTests/CitationMetaScraperParseTests.swift` — fixture-driven parser tests.
- `Tests/RubienCoreTests/KnownPaperHostClassifyTests.swift` — host + path classification table tests.
- `Tests/RubienCoreTests/PaperURLRewriteTests.swift` — PDF→landing rewrite tests.
- `Tests/RubienCoreTests/PaperURLResolverTests.swift` — orchestrator tests with stubbed `URLSession`.
- `Tests/RubienCoreTests/PaperURLExtractionTests.swift` — `MetadataFetcher.extractIdentifier` paper-URL cases.
- `Tests/RubienCoreTests/MetadataResolverPaperURLTests.swift` — end-to-end integration tests.
- `Tests/RubienCoreTests/ReferenceDuplicateCanonicalURLTests.swift` — canonical-URL dedup regression.
- `Tests/RubienTests/AddByIdentifierPaperURLUITests.swift` — Mac-only UI gating tests.
- `Tests/RubienCoreTests/PaperURLLiveSmokeTests.swift` — env-var-gated live smoke tests.
- `Scripts/refresh-citation-fixtures.sh` — fixture refresh helper.

**Modified files:**

- `Sources/RubienCore/Services/MetadataResolution.swift` — add `MetadataSource.cvfOpenAccess` and `.publisherCitationMeta` cases.
- `Sources/RubienCore/Services/MetadataFetcher.swift` — add `Identifier.paperURL(URL)` case; update `extractIdentifier`, `fetch(from:)` switch (the unified per-identifier dispatcher; verify via `grep -n "public static func fetch(from" Sources/RubienCore/Services/MetadataFetcher.swift`).
- `Sources/Rubien/Services/MetadataResolver.swift` — change `resolveIdentifierLocally` return type to tuple; add `ManualEntryOutcome` wrapper on `resolveManualEntry`; route `.paperURL` to `PaperURLResolver.resolve`.
- `Sources/Rubien/Views/AddByIdentifierView.swift` — update `onSave` signature; toggle gating logic; placeholder caption.
- `Sources/Rubien/Views/ContentView.swift` — `downloadPDFInBackground` signature; update calling code to consume `ManualEntryOutcome.result` and forward `preferredPDFURL`.
- `Sources/Rubien/Views/BatchImportView.swift` — update calls to consume `.result` from `ManualEntryOutcome`.
- `Sources/RubienCore/Services/PDFDownloadService.swift` — add `overrideURL: String?` parameter to `downloadPDF(for:)`.
- `Sources/Rubien/Resources/Localizable.xcstrings` (or equivalent localization file) — update placeholder caption key.

**Total scope:** ~1,200 LoC new code (resolver + scraper + fixtures + tests), ~80 LoC modified across existing files.

---

## Task 1: Add MetadataSource enum cases

**Files:**
- Modify: `Sources/RubienCore/Services/MetadataResolution.swift` (around line 8)

**Why first:** Subsequent tasks reference these enum cases. Two case additions with zero behavior change — safest possible first commit.

- [ ] **Step 1: Read the current enum definition**

```bash
sed -n '5,20p' /Users/hzzheng/CodeHub/Rubien/Sources/RubienCore/Services/MetadataResolution.swift
```

Expected output:
```
public enum MetadataSource: String, Codable, Sendable {
    case translationServer
    // ...
}
```

- [ ] **Step 2: Verify no exhaustive switches over MetadataSource exist**

```bash
cd /Users/hzzheng/CodeHub/Rubien
grep -rn "switch.*MetadataSource\|case \.translationServer" Sources/ Tests/ 2>/dev/null
```

Expected: matches only in `MetadataResolution.swift` itself (declaration) and in evidence-building code that reads `reference.metadataSource ?? .translationServer`. No exhaustive switches.

- [ ] **Step 3: Add the two new cases**

Edit `Sources/RubienCore/Services/MetadataResolution.swift`. Find the `MetadataSource` enum and add `cvfOpenAccess` and `publisherCitationMeta` cases:

```swift
public enum MetadataSource: String, Codable, Sendable {
    case translationServer
    case cvfOpenAccess          // NEW: paper-URL flow, CVF BibTeX adapter
    case publisherCitationMeta  // NEW: paper-URL flow, citation_* scraper
}
```

If the enum has a `var displayName` or similar computed switch, add display strings (look at existing pattern):

```swift
        case .cvfOpenAccess:         return "CVF Open Access"
        case .publisherCitationMeta: return "Publisher meta tags"
```

- [ ] **Step 4: Build and run all tests**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build 2>&1 | tail -20
swift test --filter RubienCoreTests 2>&1 | tail -20
```

Expected: build succeeds; all existing tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/hzzheng/CodeHub/Rubien
git add Sources/RubienCore/Services/MetadataResolution.swift
git commit -m "$(cat <<'EOF'
RubienCore: add MetadataSource cases for paper-URL flow

Adds .cvfOpenAccess and .publisherCitationMeta. Lands first because
subsequent paper-URL resolver work references these cases. Forward-
compatible decode: unknown raw values still fall back to nil in
ReferenceRecord.swift.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Lock BibTeX importer behavior with CVF fixtures

**Files:**
- Create: `Tests/RubienCoreTests/BibTeXImporterCVFTests.swift`

**Why:** `BibTeXImporter.parse(_:)` has no direct unit tests today — only `parseFileField` is covered. Task 3's CVF adapter depends on `BibTeXImporter.parse` producing correct `Reference` records from CVF blocks. Lock the behavior with fixtures **before** depending on it.

- [ ] **Step 1: Write the failing test file**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/BibTeXImporterCVFTests.swift`:

```swift
import XCTest
@testable import RubienCore

final class BibTeXImporterCVFTests: XCTestCase {

    // MARK: - Standard CVPR @InProceedings

    func testStandardCVPRBlock() {
        let bib = """
        @InProceedings{Smith_2024_CVPR,
            author    = {Smith, John and Doe, Jane},
            title     = {Some Paper Title},
            booktitle = {Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)},
            month     = {June},
            year      = {2024},
            pages     = {1234-1245}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        let ref = refs[0]
        XCTAssertEqual(ref.title, "Some Paper Title")
        XCTAssertEqual(ref.authors.count, 2)
        XCTAssertEqual(ref.authors[0].family, "Smith")
        XCTAssertEqual(ref.authors[1].family, "Doe")
        XCTAssertEqual(ref.year, 2024)
        XCTAssertEqual(ref.pages, "1234-1245")
        XCTAssertEqual(ref.referenceType, .conferencePaper)
        XCTAssertEqual(ref.journal, "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)")
        XCTAssertEqual(ref.eventTitle, "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)")
        XCTAssertEqual(ref.issuedMonth, 6)
    }

    // MARK: - Multi-author block

    func testMultiAuthorBlock() {
        let bib = """
        @InProceedings{Alpha_2024_ICCV,
            author    = {Alpha, A. and Beta, B. and Gamma, C. and Delta, D. and Epsilon, E.},
            title     = {Five-Author Vision Paper},
            booktitle = {Proceedings of the IEEE/CVF International Conference on Computer Vision (ICCV)},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].authors.count, 5)
    }

    // MARK: - LaTeX brace protection in title

    func testTitleWithLaTeXBraces() {
        let bib = """
        @InProceedings{Foo_2024_ECCV,
            author    = {Foo, F.},
            title     = {Foundations of {S}^n Manifold Learning},
            booktitle = {Proceedings of the European Conference on Computer Vision (ECCV)},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        // Braces are preserved as-is by BibTeXImporter (LaTeX case-protection).
        // We assert the title still parses and contains the meaningful content.
        XCTAssertTrue(refs[0].title.contains("Foundations of"))
        XCTAssertTrue(refs[0].title.contains("Manifold Learning"))
    }

    // MARK: - Bare-word month

    func testBareWordMonth() {
        let bib = """
        @InProceedings{Bar_2024_WACV,
            author    = {Bar, B.},
            title     = {Winter Vision Paper},
            booktitle = {Proceedings of the IEEE/CVF Winter Conference on Applications of Computer Vision (WACV)},
            month     = {january},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].issuedMonth, 1)
    }

    // MARK: - Block followed by HTML noise (mimics <pre> extraction)

    func testBlockFollowedByHTMLNoise() {
        let bib = """
        @InProceedings{Baz_2024_CVPR,
            author    = {Baz, B.},
            title     = {HTML-Noise Robustness},
            booktitle = {Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)},
            year      = {2024}
        }
        </pre>
        <div class="footer">Copyright 2024</div>
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].title, "HTML-Noise Robustness")
    }

    // MARK: - Block without doi field (CVF norm)

    func testBlockWithoutDOI() {
        let bib = """
        @InProceedings{Qux_2024_CVPR,
            author    = {Qux, Q.},
            title     = {No DOI Here},
            booktitle = {CVPR 2024},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertNil(refs[0].doi)
    }

    // MARK: - Multi-line title (line-wrapped BibTeX)

    func testMultiLineTitle() {
        let bib = """
        @InProceedings{Wrap_2024_CVPR,
            author    = {Wrap, W.},
            title     = {A Very Long Title That Wraps
                         Across Multiple Lines in the BibTeX Source},
            booktitle = {CVPR 2024},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        // Title should contain both halves; importer may preserve newlines or
        // collapse whitespace — assert content rather than exact form.
        XCTAssertTrue(refs[0].title.contains("Long Title"))
        XCTAssertTrue(refs[0].title.contains("Multiple Lines"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.BibTeXImporterCVFTests 2>&1 | tail -30
```

Expected: all 7 tests pass. If any fail, that's a real BibTeX importer bug — investigate before proceeding. (The spec acknowledges `parse(_:)` had no direct tests; surprises are possible.)

- [ ] **Step 3: Commit**

```bash
cd /Users/hzzheng/CodeHub/Rubien
git add Tests/RubienCoreTests/BibTeXImporterCVFTests.swift
git commit -m "$(cat <<'EOF'
RubienCore tests: lock BibTeXImporter behavior on CVF blocks

BibTeXImporter.parse(_:) is used by CLI, app, and Zotero import but
has no direct unit tests today. Task 3 (paper-URL resolver) depends
on it for CVF Open Access landing-page parsing. These fixtures cover
the @InProceedings shapes CVF emits: multi-author, LaTeX brace
protection, bare-word month, surrounded-by-HTML noise, missing doi,
multi-line title.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: CitationMetaScraper + PaperURLResolver (bundled commit)

**Files (all new):**
- Create: `Sources/RubienCore/Services/CitationMetaScraper.swift`
- Create: `Sources/RubienCore/Services/PaperURLResolver.swift`
- Create: `Tests/RubienCoreTests/CitationMetaScraperParseTests.swift`
- Create: `Tests/RubienCoreTests/KnownPaperHostClassifyTests.swift`
- Create: `Tests/RubienCoreTests/PaperURLRewriteTests.swift`
- Create: `Tests/RubienCoreTests/PaperURLResolverTests.swift`
- Create: `Tests/RubienCoreTests/Fixtures/CitationMeta/openreview-forum.html`
- Create: `Tests/RubienCoreTests/Fixtures/CitationMeta/aclanthology-paper.html`
- Create: `Tests/RubienCoreTests/Fixtures/CitationMeta/cvf-paper.html`
- Create: `Tests/RubienCoreTests/Fixtures/CitationMeta/no-citation-meta.html`
- Create: `Tests/RubienCoreTests/Fixtures/CitationMeta/paywall-login-page.html`
- Create: `Tests/RubienCoreTests/Fixtures/CitationMeta/relative-pdf-url.html`
- Create: `Tests/RubienCoreTests/Fixtures/CitationMeta/FIXTURE-NOTES.md`

**Why bundled:** `CitationMetaScraper.fetch` performs a redirect-host check against `KnownPaperHost.classify`, defined in `PaperURLResolver.swift`. Both adapters share the internal `fetchHTML(url:session:)` helper, also in `PaperURLResolver.swift`. Shipping `CitationMetaScraper.swift` alone would not compile.

This is the largest task in the plan. Substeps 3.A through 3.J build up incrementally with TDD where practical.

### 3.A — Skeleton files (compile-only)

- [ ] **Step 1: Create `PaperURLResolver.swift` skeleton**

Create `/Users/hzzheng/CodeHub/Rubien/Sources/RubienCore/Services/PaperURLResolver.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Public API

/// Resolves paper-landing-page URLs to authoritative Reference records.
/// Stateless enum, callable from any actor context.
public enum PaperURLResolver {
    public struct Outcome: Sendable {
        public let reference: Reference
        public let scrapedPDFURL: String?
    }

    public enum ResolveError: Error, Sendable {
        case unknownHost
        case unsupportedScheme
        case fetchFailed(statusCode: Int, host: String)
        case redirectedAwayFromAllowlist(finalHost: String)
        case unexpectedContentType(String)
        case insufficientMetadata
        case bibtexNotFound
        case bibtexEmpty
        /// Empty `Reference.authors` after merge. Payload includes the
        /// partially-scraped Reference so the caller can construct a
        /// CandidateEnvelope for user review per spec §4. scrapedPDFURL
        /// is included for completeness but the caller will discard it
        /// (preferredPDFURL is .verified-only).
        case noAuthorsAvailable(reference: Reference, scrapedPDFURL: String?)
        case timedOut
        case networkUnavailable
    }

    public static func resolve(
        _ url: URL,
        session: URLSession = .shared
    ) async throws -> Outcome {
        fatalError("not yet implemented — see substeps 3.D / 3.G / 3.H")
    }
}

// MARK: - KnownPaperHost (internal)

internal enum KnownPaperHost: CaseIterable {
    case openReview
    case aclAnthology
    case cvfOpenAccess
    case neurIPS         // papers.nips.cc
    case neurIPSProceedings  // proceedings.neurips.cc
    case pmlr
    case ieeeXplore
    case acmDL
    case nature
    case springer
    case scienceDirect

    static func classify(_ url: URL) -> KnownPaperHost? {
        fatalError("not yet implemented — see substep 3.C")
    }
}

// MARK: - URL canonicalization

internal extension PaperURLResolver {
    static func canonicalize(_ url: URL) -> URL? {
        fatalError("not yet implemented — see substep 3.B")
    }
}

// MARK: - PDF → landing rewrite

internal extension PaperURLResolver {
    static func rewritePDFURLToLanding(_ url: URL, host: KnownPaperHost) -> URL {
        fatalError("not yet implemented — see substep 3.E")
    }
}

// MARK: - Shared HTTP helper

internal struct PaperURLHTTPResponse: Sendable {
    let data: Data
    let finalURL: URL
    let contentType: String?
}

internal extension PaperURLResolver {
    /// Performs an HTTP GET with retry, content-type filtering, and a redirect-host
    /// check against the KnownPaperHost allowlist. Used by both CitationMetaScraper
    /// and the CVF BibTeX adapter.
    ///
    /// Retry contract (matches CitationMetaScraper §2.1):
    /// - URLError.timedOut: retry, 1s base, exponential
    /// - URLError.networkConnectionLost: retry, 1s base, exponential
    /// - HTTP 5xx: retry, 1s base, exponential
    /// - HTTP 429: retry, 3s base, exponential
    /// - Everything else: throw immediately
    static func fetchHTML(
        url: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15,
        maxAttempts: Int = 3
    ) async throws -> PaperURLHTTPResponse {
        fatalError("not yet implemented — see substep 3.F")
    }
}
```

- [ ] **Step 2: Create `CitationMetaScraper.swift` skeleton**

Create `/Users/hzzheng/CodeHub/Rubien/Sources/RubienCore/Services/CitationMetaScraper.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CitationMetaResult: Sendable, Equatable {
    public var title: String?
    public var authors: [AuthorName]
    public var year: Int?
    public var journal: String?
    public var conferenceTitle: String?
    public var volume: String?
    public var issue: String?
    public var firstPage: String?
    public var lastPage: String?
    public var doi: String?
    public var isbn: String?
    public var issn: String?
    public var abstract: String?
    public var pdfURL: String?
    public var publisher: String?

    public init() {
        self.authors = []
    }
}

public enum CitationMetaScraper {
    public static func fetch(
        _ url: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15
    ) async throws -> CitationMetaResult {
        let response = try await PaperURLResolver.fetchHTML(url: url, session: session, timeout: timeout)
        let html = String(data: response.data, encoding: .utf8) ?? ""
        return parse(html: html, baseURL: response.finalURL)
    }

    public static func parse(html: String, baseURL: URL) -> CitationMetaResult {
        fatalError("not yet implemented — see substep 3.D")
    }
}
```

- [ ] **Step 3: Build and confirm skeleton compiles**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build 2>&1 | tail -10
```

Expected: success. (The `fatalError` calls compile fine — they're runtime traps, not compile-time errors.)

### 3.B — URL canonicalization (TDD)

- [ ] **Step 1: Write the failing tests**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/KnownPaperHostClassifyTests.swift`:

```swift
import XCTest
@testable import RubienCore

final class URLCanonicalizationTests: XCTestCase {

    private func canonicalize(_ s: String) -> String? {
        guard let url = URL(string: s) else { return nil }
        return PaperURLResolver.canonicalize(url)?.absoluteString
    }

    func testLowercaseHost() {
        XCTAssertEqual(canonicalize("https://OPENREVIEW.NET/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testLowercaseScheme() {
        XCTAssertEqual(canonicalize("HTTPS://openreview.net/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testStripWWWPrefix() {
        XCTAssertEqual(canonicalize("https://www.nature.com/articles/foo"),
                       "https://nature.com/articles/foo")
    }

    func testStripFragment() {
        XCTAssertEqual(canonicalize("https://openreview.net/forum?id=ABCD#section-2"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testUpgradeHTTPToHTTPS() {
        // Spec §2.4: "If both work for a publisher, store as https." All 10
        // target hosts support https; canonicalize unconditionally upgrades.
        XCTAssertEqual(canonicalize("http://openreview.net/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testStripDefaultPort80AndUpgrade() {
        // http://...:80 becomes https://... (no port).
        XCTAssertEqual(canonicalize("http://openreview.net:80/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testStripDefaultPort443() {
        XCTAssertEqual(canonicalize("https://openreview.net:443/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testPreserveTrailingSlash() {
        XCTAssertEqual(canonicalize("https://aclanthology.org/2024.acl-long.123/"),
                       "https://aclanthology.org/2024.acl-long.123/")
    }

    func testPreservePathCase() {
        // CVF paths are case-sensitive; preserve.
        XCTAssertEqual(canonicalize("https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html"),
                       "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html")
    }

    func testPreserveQueryOrder() {
        // Query params not reordered; OpenReview routing depends on ?id=.
        XCTAssertEqual(canonicalize("https://openreview.net/forum?id=ABCD&noteId=XYZ"),
                       "https://openreview.net/forum?id=ABCD&noteId=XYZ")
    }

    func testRejectEmbeddedCredentials() {
        XCTAssertNil(canonicalize("https://user:pass@openreview.net/forum?id=ABCD"))
    }

    func testRejectUnsupportedScheme() {
        XCTAssertNil(canonicalize("ftp://openreview.net/forum?id=ABCD"))
        XCTAssertNil(canonicalize("file:///etc/passwd"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.URLCanonicalizationTests 2>&1 | tail -20
```

Expected: all fail with the `fatalError("not yet implemented…")` trap.

- [ ] **Step 3: Implement `canonicalize`**

Replace the `canonicalize` stub in `PaperURLResolver.swift`:

```swift
internal extension PaperURLResolver {
    static func canonicalize(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // Validate scheme. Reject if not http or https.
        guard let rawScheme = components.scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https" else { return nil }

        // Reject embedded credentials.
        if components.user != nil || components.password != nil { return nil }

        // Lowercase host, strip www. for matching.
        guard let rawHost = components.host?.lowercased() else { return nil }
        let strippedHost = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        components.host = strippedHost

        // Upgrade http -> https. Per spec §2.4: "If both work for a publisher,
        // store as https." All 10 target hosts support https; this also covers
        // default-port stripping in one move (an http://...:80 becomes https://...).
        components.scheme = "https"

        // Strip default ports (80 and 443).
        if components.port == 80 || components.port == 443 {
            components.port = nil
        }

        // Strip fragment.
        components.fragment = nil

        return components.url
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.URLCanonicalizationTests 2>&1 | tail -20
```

Expected: all 11 tests pass.

### 3.C — KnownPaperHost.classify (TDD)

- [ ] **Step 1: Append classification tests to `KnownPaperHostClassifyTests.swift`**

```swift
final class KnownPaperHostClassifyTests: XCTestCase {

    private func classify(_ s: String) -> KnownPaperHost? {
        guard let url = URL(string: s) else { return nil }
        return KnownPaperHost.classify(url)
    }

    // OpenReview
    func testOpenReviewLanding() {
        XCTAssertEqual(classify("https://openreview.net/forum?id=ABCD"), .openReview)
    }
    func testOpenReviewPDF() {
        XCTAssertEqual(classify("https://openreview.net/pdf?id=ABCD"), .openReview)
    }
    func testOpenReviewMissingQuery() {
        // No ?id= → not a paper URL
        XCTAssertNil(classify("https://openreview.net/forum"))
    }
    func testOpenReviewHomepage() {
        XCTAssertNil(classify("https://openreview.net/"))
    }

    // ACL Anthology
    func testACLLanding() {
        XCTAssertEqual(classify("https://aclanthology.org/2024.acl-long.123/"), .aclAnthology)
    }
    func testACLLandingNoTrailingSlash() {
        XCTAssertEqual(classify("https://aclanthology.org/2024.acl-long.123"), .aclAnthology)
    }
    func testACLPDF() {
        XCTAssertEqual(classify("https://aclanthology.org/2024.acl-long.123.pdf"), .aclAnthology)
    }
    func testACLFindings() {
        XCTAssertEqual(classify("https://aclanthology.org/2024.findings-emnlp.42/"), .aclAnthology)
    }
    func testACLHomepage() {
        XCTAssertNil(classify("https://aclanthology.org/"))
    }

    // CVF
    func testCVFLanding() {
        XCTAssertEqual(classify("https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html"), .cvfOpenAccess)
    }
    func testCVFPDF() {
        XCTAssertEqual(classify("https://openaccess.thecvf.com/content/CVPR2024/papers/Foo_paper.pdf"), .cvfOpenAccess)
    }
    func testCVFHomepage() {
        XCTAssertNil(classify("https://openaccess.thecvf.com/"))
    }

    // NeurIPS
    func testNeurIPSLegacyLanding() {
        XCTAssertEqual(classify("https://papers.nips.cc/paper/2020/hash/abc.html"), .neurIPS)
    }
    func testNeurIPSLegacyPDF() {
        XCTAssertEqual(classify("https://papers.nips.cc/paper/2020/file/abc.pdf"), .neurIPS)
    }
    func testNeurIPSModernLanding() {
        XCTAssertEqual(classify("https://proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Conference.html"), .neurIPSProceedings)
    }
    func testNeurIPSModernPDF() {
        XCTAssertEqual(classify("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Conference.pdf"), .neurIPSProceedings)
    }
    func testNeurIPSDatasetsTrack() {
        XCTAssertEqual(classify("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Datasets_and_Benchmarks_Track.pdf"), .neurIPSProceedings)
    }

    // PMLR
    func testPMLRLanding() {
        XCTAssertEqual(classify("https://proceedings.mlr.press/v200/foo23a.html"), .pmlr)
    }
    func testPMLRPDF() {
        XCTAssertEqual(classify("https://proceedings.mlr.press/v200/foo23a/foo23a.pdf"), .pmlr)
    }

    // IEEE
    func testIEEEDocument() {
        XCTAssertEqual(classify("https://ieeexplore.ieee.org/document/1234567"), .ieeeXplore)
    }
    func testIEEEAbstract() {
        XCTAssertEqual(classify("https://ieeexplore.ieee.org/abstract/document/1234567"), .ieeeXplore)
    }
    func testIEEEStampPDF() {
        XCTAssertEqual(classify("https://ieeexplore.ieee.org/stamp/stamp.jsp"), .ieeeXplore)
    }
    func testIEEEJournalHomepage() {
        // Not a paper URL — falls through
        XCTAssertNil(classify("https://ieeexplore.ieee.org/journal/12345"))
    }

    // ACM
    func testACMLanding() {
        XCTAssertEqual(classify("https://dl.acm.org/doi/10.1145/foo.bar"), .acmDL)
    }
    func testACMAbs() {
        XCTAssertEqual(classify("https://dl.acm.org/doi/abs/10.1145/foo.bar"), .acmDL)
    }
    func testACMPDF() {
        XCTAssertEqual(classify("https://dl.acm.org/doi/pdf/10.1145/foo.bar"), .acmDL)
    }

    // Nature
    func testNatureArticle() {
        XCTAssertEqual(classify("https://nature.com/articles/s41586-024-12345-6"), .nature)
    }
    func testNatureWWWArticle() {
        XCTAssertEqual(classify("https://www.nature.com/articles/s41586-024-12345-6"), .nature)
    }
    func testNaturePDF() {
        XCTAssertEqual(classify("https://nature.com/articles/s41586-024-12345-6.pdf"), .nature)
    }
    func testNatureHomepage() {
        XCTAssertNil(classify("https://nature.com/"))
    }

    // Springer
    func testSpringerArticle() {
        XCTAssertEqual(classify("https://link.springer.com/article/10.1007/s11042-024-12345-6"), .springer)
    }
    func testSpringerChapter() {
        XCTAssertEqual(classify("https://link.springer.com/chapter/10.1007/978-3-540-24777-7_1"), .springer)
    }
    func testSpringerBook() {
        XCTAssertEqual(classify("https://link.springer.com/book/10.1007/978-3-030-12345-6"), .springer)
    }
    func testSpringerContentPDF_NotAccepted() {
        // No Springer PDF rewrite; should fall through.
        XCTAssertNil(classify("https://link.springer.com/content/pdf/10.1007/foo.pdf"))
    }
    func testSpringerSearch() {
        XCTAssertNil(classify("https://link.springer.com/search?query=foo"))
    }

    // ScienceDirect
    func testScienceDirectPII() {
        XCTAssertEqual(classify("https://www.sciencedirect.com/science/article/pii/S0123456789012345"), .scienceDirect)
    }
    func testScienceDirectAbsPII() {
        XCTAssertEqual(classify("https://www.sciencedirect.com/science/article/abs/pii/S0123456789012345"), .scienceDirect)
    }
    func testScienceDirectPDFFT() {
        XCTAssertEqual(classify("https://www.sciencedirect.com/science/article/pii/S0123456789012345/pdfft"), .scienceDirect)
    }

    // Negatives — random hosts
    func testRandomBlog() {
        XCTAssertNil(classify("https://example-blog.com/post/hello"))
    }
    func testGoogle() {
        XCTAssertNil(classify("https://www.google.com/search?q=foo"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.KnownPaperHostClassifyTests 2>&1 | tail -10
```

Expected: all fail at the `fatalError` trap.

- [ ] **Step 3: Implement `KnownPaperHost.classify`**

Replace the stub in `PaperURLResolver.swift`:

```swift
internal enum KnownPaperHost: CaseIterable {
    case openReview, aclAnthology, cvfOpenAccess
    case neurIPS, neurIPSProceedings
    case pmlr, ieeeXplore, acmDL, nature, springer, scienceDirect

    /// Returns the host bucket if the URL matches both a known host and a
    /// known path shape (landing OR PDF). Returns nil otherwise — callers
    /// fall through to existing identifier extraction.
    static func classify(_ url: URL) -> KnownPaperHost? {
        guard let canonical = PaperURLResolver.canonicalize(url) else { return nil }
        guard let host = canonical.host else { return nil }
        let path = canonical.path
        let query = canonical.query

        switch host {
        case "openreview.net":
            // Requires ?id=... in query.
            guard query?.contains("id=") == true else { return nil }
            if path == "/forum" || path == "/pdf" { return .openReview }
            return nil
        case "aclanthology.org":
            if matches(path, pattern: #"^/\d{4}\.[a-z]+-(long|short|industry|tutorial|demo|main|findings)\.\d+/?$"#) { return .aclAnthology }
            if matches(path, pattern: #"^/\d{4}\.[a-z]+-(long|short|industry|tutorial|demo|main|findings)\.\d+\.pdf$"#) { return .aclAnthology }
            return nil
        case "openaccess.thecvf.com":
            if matches(path, pattern: #"^/content/[^/]+/html/.+\.html$"#) { return .cvfOpenAccess }
            if matches(path, pattern: #"^/content/[^/]+/papers/.+\.pdf$"#) { return .cvfOpenAccess }
            return nil
        case "papers.nips.cc":
            if matches(path, pattern: #"^/paper/\d+/hash/.+\.html$"#) { return .neurIPS }
            if matches(path, pattern: #"^/paper/\d+/file/.+\.pdf$"#) { return .neurIPS }
            return nil
        case "proceedings.neurips.cc":
            if matches(path, pattern: #"^/paper_files/paper/\d+/hash/.+\.html$"#) { return .neurIPSProceedings }
            if matches(path, pattern: #"^/paper_files/paper/\d+/file/.+\.pdf$"#) { return .neurIPSProceedings }
            return nil
        case "proceedings.mlr.press":
            if matches(path, pattern: #"^/v\d+/[^/]+\.html$"#) { return .pmlr }
            if matches(path, pattern: #"^/v\d+/[^/]+/[^/]+\.pdf$"#) { return .pmlr }
            return nil
        case "ieeexplore.ieee.org":
            if matches(path, pattern: #"^/(document|abstract/document)/\d+/?$"#) { return .ieeeXplore }
            if matches(path, pattern: #"^/stamp/stamp\.jsp$"#) { return .ieeeXplore }
            return nil
        case "dl.acm.org":
            if matches(path, pattern: #"^/doi/(abs/)?10\.\d+/.+$"#) { return .acmDL }
            if matches(path, pattern: #"^/doi/pdf/10\.\d+/.+$"#) { return .acmDL }
            return nil
        case "nature.com":
            if matches(path, pattern: #"^/articles/.+\.pdf$"#) { return .nature }
            if matches(path, pattern: #"^/articles/.+$"#) { return .nature }
            return nil
        case "link.springer.com":
            // Landing only — no PDF rewrite for Springer (see spec §2.3.B).
            if matches(path, pattern: #"^/(article|chapter|book|referenceworkentry)/.+$"#) { return .springer }
            return nil
        case "sciencedirect.com":
            if matches(path, pattern: #"^/science/article/.+/pdfft$"#) { return .scienceDirect }
            if matches(path, pattern: #"^/science/article/(pii|abs/pii)/.+$"#) { return .scienceDirect }
            return nil
        default:
            return nil
        }
    }

    private static func matches(_ string: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.KnownPaperHostClassifyTests 2>&1 | tail -20
```

Expected: all tests pass.

### 3.D — CitationMetaScraper.parse (TDD)

- [ ] **Step 1: Create test fixtures**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/Fixtures/CitationMeta/openreview-forum.html`:

```html
<!--
SOURCE: https://openreview.net/forum?id=EXAMPLE
CAPTURED: 2026-05-16 (synthetic — replace with live capture before shipping)
-->
<!DOCTYPE html>
<html>
<head>
<meta name="citation_title" content="Attention Is All You Need">
<meta name="citation_author" content="Vaswani, Ashish">
<meta name="citation_author" content="Shazeer, Noam">
<meta name="citation_publication_date" content="2017/06/12">
<meta name="citation_conference_title" content="NeurIPS 2017">
<meta name="citation_abstract" content="The dominant sequence transduction models are based on complex recurrent or convolutional neural networks.">
<meta name="citation_pdf_url" content="https://openreview.net/pdf?id=EXAMPLE">
<title>Attention Is All You Need | OpenReview</title>
</head>
<body><h1>Paper details</h1></body>
</html>
```

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/Fixtures/CitationMeta/aclanthology-paper.html`:

```html
<!--
SOURCE: https://aclanthology.org/EXAMPLE.acl-long.123/
CAPTURED: 2026-05-16 (synthetic)
-->
<!DOCTYPE html>
<html>
<head>
<meta name="citation_title" content="A Sample ACL Paper">
<meta name="citation_author" content="Doe, Jane">
<meta name="citation_author" content="Smith, John">
<meta name="citation_publication_date" content="2024">
<meta name="citation_conference_title" content="ACL 2024">
<meta name="citation_doi" content="10.18653/v1/2024.acl-long.123">
<meta name="citation_pdf_url" content="https://aclanthology.org/2024.acl-long.123.pdf">
<meta name="citation_firstpage" content="100">
<meta name="citation_lastpage" content="115">
<title>A Sample ACL Paper - ACL Anthology</title>
</head>
<body></body>
</html>
```

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/Fixtures/CitationMeta/relative-pdf-url.html`:

```html
<!--
SOURCE: synthetic; mimics ACM/IEEE relative pdf paths
-->
<!DOCTYPE html>
<html>
<head>
<meta name="citation_title" content="Paper With Relative PDF URL">
<meta name="citation_author" content="Author, A.">
<meta name="citation_publication_date" content="2024">
<meta name="citation_doi" content="10.1145/foo.bar">
<meta name="citation_pdf_url" content="/doi/pdf/10.1145/foo.bar">
<title>Test</title>
</head>
<body></body>
</html>
```

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/Fixtures/CitationMeta/no-citation-meta.html`:

```html
<!--
SOURCE: synthetic plain HTML, no citation_* tags
-->
<!DOCTYPE html>
<html>
<head><title>A Regular Web Page</title></head>
<body><h1>Hello</h1></body>
</html>
```

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/Fixtures/CitationMeta/paywall-login-page.html`:

```html
<!--
SOURCE: synthetic; mimics a typical paywall interstitial
-->
<!DOCTYPE html>
<html>
<head>
<title>Access through your institution - ScienceDirect</title>
</head>
<body>
<form action="/login"><input name="user"></form>
</body>
</html>
```

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/Fixtures/CitationMeta/cvf-paper.html`:

```html
<!--
SOURCE: synthetic CVF Open Access page
-->
<!DOCTYPE html>
<html>
<head><title>CVF Paper Title - CVPR 2024</title></head>
<body>
<div id="papertitle">A Sample CVPR Paper</div>
<div id="authors">Some Author, Another Author</div>
<pre>
@InProceedings{Sample_2024_CVPR,
    author    = {Author, Some and Author, Another},
    title     = {A Sample CVPR Paper},
    booktitle = {Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)},
    month     = {June},
    year      = {2024},
    pages     = {100-115}
}
</pre>
</body>
</html>
```

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/Fixtures/CitationMeta/FIXTURE-NOTES.md`:

```markdown
# Citation Meta Fixtures

These HTML fixtures back `CitationMetaScraperParseTests` and `PaperURLResolverTests`.

## Synthetic vs. captured

The initial set is **synthetic** — small hand-written HTML files that exercise
the parser's specific code paths (relative-PDF resolution, paywall detection,
missing citation_*, etc.). They are not meant to mirror a real publisher's
page byte-for-byte.

Before shipping, capture **real HTML** from each target site and verify the
parser produces the same fields. Replace each synthetic fixture with the real
one, keeping the comment header noting source URL and capture date.

## Refresh procedure

When a fixture starts failing (because a site redesigned its meta tags):

1. Open the source URL in a browser; "View Source" or `curl -A "Rubien/1.0" <url>`.
2. Save the entire `<head>` (or full document) into the fixture file.
3. Update the comment header's CAPTURED date.
4. Run `swift test --filter CitationMetaScraperParseTests`.
5. If the test expectations now mismatch, update the assertions to match the
   new meta-tag set. Open a GitHub issue noting which site changed.

## Sites covered

| Fixture | Live source |
|---|---|
| openreview-forum.html | https://openreview.net/forum?id=<some-real-id> |
| aclanthology-paper.html | https://aclanthology.org/<some-real-paper>/ |
| cvf-paper.html | https://openaccess.thecvf.com/content/<conf>/html/<paper>.html |
| neurips-proceedings.html | https://proceedings.neurips.cc/... (capture before shipping) |
| pmlr-paper.html | https://proceedings.mlr.press/... (capture before shipping) |
| ieee-xplore.html | https://ieeexplore.ieee.org/document/... (capture before shipping) |
| nature-article.html | https://nature.com/articles/... (capture before shipping) |
| springer-chapter.html | https://link.springer.com/chapter/... (capture before shipping) |
| acm-dl.html | https://dl.acm.org/doi/... (capture before shipping) |
| sciencedirect-article.html | https://www.sciencedirect.com/science/article/pii/... (capture before shipping) |

Smoke tests (`PaperURLLiveSmokeTests.swift`) gated behind `RUBIEN_LIVE_TESTS=1`
hit these live URLs and assert minimum fields (`title`, `authors`, `year`).
```

(These are the minimum fixtures needed for the parse tests to function. The remaining 6 site fixtures listed in FIXTURE-NOTES are captured during pre-ship live verification or by running the smoke tests in §3.J/Task 7. They are not blocking for Task 3.)

- [ ] **Step 2: Add resource handling to `Package.swift`**

Edit `/Users/hzzheng/CodeHub/Rubien/Package.swift`. Find the `RubienCoreTests` target and add a `resources` entry:

```swift
.testTarget(
    name: "RubienCoreTests",
    dependencies: ["RubienCore"],
    resources: [
        .copy("Fixtures/CitationMeta")
    ]
),
```

(If a `resources:` array already exists, append the `.copy("Fixtures/CitationMeta")` entry.)

- [ ] **Step 3: Write the failing parse tests**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/CitationMetaScraperParseTests.swift`:

```swift
import XCTest
@testable import RubienCore

final class CitationMetaScraperParseTests: XCTestCase {

    private func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: "CitationMeta/\(name)", withExtension: "html")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    private func baseURL(_ s: String) -> URL { URL(string: s)! }

    // MARK: - OpenReview

    func testOpenReviewExtraction() {
        let html = loadFixture("openreview-forum")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://openreview.net/forum?id=EXAMPLE")
        )
        XCTAssertEqual(result.title, "Attention Is All You Need")
        XCTAssertEqual(result.authors.count, 2)
        XCTAssertEqual(result.authors[0].family, "Vaswani")
        XCTAssertEqual(result.authors[1].family, "Shazeer")
        XCTAssertEqual(result.year, 2017)
        XCTAssertEqual(result.conferenceTitle, "NeurIPS 2017")
        XCTAssertEqual(result.pdfURL, "https://openreview.net/pdf?id=EXAMPLE")
        XCTAssertNil(result.doi)
    }

    // MARK: - ACL with DOI

    func testACLExtractionWithDOI() {
        let html = loadFixture("aclanthology-paper")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://aclanthology.org/2024.acl-long.123/")
        )
        XCTAssertEqual(result.title, "A Sample ACL Paper")
        XCTAssertEqual(result.authors.count, 2)
        XCTAssertEqual(result.doi, "10.18653/v1/2024.acl-long.123")
        XCTAssertEqual(result.firstPage, "100")
        XCTAssertEqual(result.lastPage, "115")
        XCTAssertEqual(result.conferenceTitle, "ACL 2024")
    }

    // MARK: - Relative citation_pdf_url

    func testRelativePDFURL() {
        let html = loadFixture("relative-pdf-url")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://dl.acm.org/doi/10.1145/foo.bar")
        )
        XCTAssertEqual(result.pdfURL, "https://dl.acm.org/doi/pdf/10.1145/foo.bar")
    }

    // MARK: - No citation_* tags

    func testNoCitationMeta() {
        let html = loadFixture("no-citation-meta")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://example.com/")
        )
        XCTAssertNil(result.title)
        XCTAssertTrue(result.authors.isEmpty)
        XCTAssertNil(result.doi)
        XCTAssertNil(result.pdfURL)
    }

    // MARK: - Paywall page (citation_* absent)

    func testPaywallExtractsNothing() {
        let html = loadFixture("paywall-login-page")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://www.sciencedirect.com/login")
        )
        // The scraper does NOT fall back to <title>; result.title is nil.
        XCTAssertNil(result.title)
        XCTAssertTrue(result.authors.isEmpty)
    }

    // MARK: - Year parsing variants

    func testYearFromFullDate() {
        let html = """
        <html><head>
        <meta name="citation_title" content="X">
        <meta name="citation_publication_date" content="2024/06/12">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.year, 2024)
    }

    func testYearFromBareYear() {
        let html = """
        <html><head>
        <meta name="citation_title" content="X">
        <meta name="citation_year" content="2023">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.year, 2023)
    }

    func testYearFromISODate() {
        let html = """
        <html><head>
        <meta name="citation_title" content="X">
        <meta name="citation_publication_date" content="2024-06-12">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.year, 2024)
    }

    // MARK: - Multiple citation_author tags collected in order

    func testMultipleAuthorsInOrder() {
        let html = """
        <html><head>
        <meta name="citation_title" content="X">
        <meta name="citation_author" content="First, A.">
        <meta name="citation_author" content="Second, B.">
        <meta name="citation_author" content="Third, C.">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.authors.count, 3)
        XCTAssertEqual(result.authors.map(\.family), ["First", "Second", "Third"])
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.CitationMetaScraperParseTests 2>&1 | tail -20
```

Expected: all tests fail at the `fatalError` trap (or earlier with a fixture-load error if `Package.swift` resources weren't picked up).

- [ ] **Step 5: Implement `CitationMetaScraper.parse`**

Replace the stub in `Sources/RubienCore/Services/CitationMetaScraper.swift`. Add this implementation:

```swift
public enum CitationMetaScraper {
    public static func fetch(
        _ url: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15
    ) async throws -> CitationMetaResult {
        let response = try await PaperURLResolver.fetchHTML(url: url, session: session, timeout: timeout)
        let html = String(data: response.data, encoding: .utf8) ?? ""
        return parse(html: html, baseURL: response.finalURL)
    }

    public static func parse(html: String, baseURL: URL) -> CitationMetaResult {
        var result = CitationMetaResult()
        let tags = extractMetaTags(from: html)

        // Multi-value tags
        let authorValues = tags.filter { $0.name == "citation_author" }.map(\.content)
        result.authors = authorValues.flatMap { AuthorName.parseList($0) }

        // Single-value tags
        for (name, content) in tags.map({ ($0.name, $0.content) }) {
            switch name {
            case "citation_title":             result.title = content
            case "citation_journal_title":     result.journal = content
            case "citation_conference_title":  result.conferenceTitle = content
            case "citation_volume":            result.volume = content
            case "citation_issue":             result.issue = content
            case "citation_firstpage":         result.firstPage = content
            case "citation_lastpage":          result.lastPage = content
            case "citation_doi":               result.doi = content
            case "citation_isbn":              result.isbn = content
            case "citation_issn":              result.issn = content
            case "citation_publisher":         result.publisher = content
            case "citation_abstract":          result.abstract = content
            case "citation_publication_date":
                if result.year == nil { result.year = parseYear(content) }
            case "citation_year":
                result.year = parseYear(content) ?? result.year
            case "citation_pdf_url":
                result.pdfURL = resolveAbsolute(content, baseURL: baseURL)
            case "og:description":
                if result.abstract == nil { result.abstract = content }
            default:
                break
            }
        }

        return result
    }

    // MARK: - Internals

    private struct MetaTag {
        let name: String
        let content: String
    }

    /// Scans the <head> section for <meta name="..." content="..."> tags.
    /// Pattern is generous about attribute order and quoting style.
    private static func extractMetaTags(from html: String) -> [MetaTag] {
        // Restrict to <head>...</head> if present; fall back to whole document.
        let scope: String = {
            if let headStart = html.range(of: "<head", options: .caseInsensitive),
               let headEnd = html.range(of: "</head>", options: .caseInsensitive, range: headStart.upperBound..<html.endIndex) {
                return String(html[headStart.lowerBound..<headEnd.upperBound])
            }
            return html
        }()

        // Match <meta ... name="X" ... content="Y"> and the reversed attribute order.
        let patterns = [
            #"<meta\s+[^>]*name\s*=\s*["']([^"']+)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*/?>"#,
            #"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*name\s*=\s*["']([^"']+)["'][^>]*/?>"#,
        ]

        var tags: [MetaTag] = []
        for (idx, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(scope.startIndex..., in: scope)
            regex.enumerateMatches(in: scope, options: [], range: range) { match, _, _ in
                guard let match = match,
                      let r1 = Range(match.range(at: 1), in: scope),
                      let r2 = Range(match.range(at: 2), in: scope) else { return }
                let (name, content) = idx == 0
                    ? (String(scope[r1]).lowercased(), String(scope[r2]))
                    : (String(scope[r2]).lowercased(), String(scope[r1]))
                tags.append(MetaTag(name: name, content: decodeHTMLEntities(content)))
            }
        }
        return tags
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func parseYear(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try bare 4-digit year first.
        if trimmed.count == 4, let n = Int(trimmed), (1500...2200).contains(n) { return n }
        // Else extract the first 4-digit substring.
        let pattern = #"(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let yearRange = Range(match.range(at: 1), in: trimmed),
              let year = Int(trimmed[yearRange]),
              (1500...2200).contains(year) else { return nil }
        return year
    }

    private static func resolveAbsolute(_ rawURL: String, baseURL: URL) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url.absoluteString }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteString
    }
}
```

- [ ] **Step 6: Run the parse tests to verify they pass**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.CitationMetaScraperParseTests 2>&1 | tail -20
```

Expected: all parse tests pass.

### 3.E — PDF → landing rewrite (TDD)

- [ ] **Step 1: Write the failing tests**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/PaperURLRewriteTests.swift`:

```swift
import XCTest
@testable import RubienCore

final class PaperURLRewriteTests: XCTestCase {

    private func rewrite(_ s: String) -> String? {
        guard let url = URL(string: s),
              let host = KnownPaperHost.classify(url) else { return nil }
        return PaperURLResolver.rewritePDFURLToLanding(url, host: host).absoluteString
    }

    func testOpenReviewPDFRewrite() {
        XCTAssertEqual(rewrite("https://openreview.net/pdf?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testOpenReviewLandingNoChange() {
        XCTAssertEqual(rewrite("https://openreview.net/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testACLPDFRewrite() {
        XCTAssertEqual(rewrite("https://aclanthology.org/2024.acl-long.123.pdf"),
                       "https://aclanthology.org/2024.acl-long.123/")
    }

    func testCVFPDFRewrite() {
        XCTAssertEqual(rewrite("https://openaccess.thecvf.com/content/CVPR2024/papers/Foo_paper.pdf"),
                       "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html")
    }

    func testNeurIPSLegacyPDFRewrite() {
        XCTAssertEqual(rewrite("https://papers.nips.cc/paper/2020/file/abc.pdf"),
                       "https://papers.nips.cc/paper/2020/hash/abc.html")
    }

    func testNeurIPSModernPDFRewriteMainTrack() {
        XCTAssertEqual(rewrite("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Conference.pdf"),
                       "https://proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Conference.html")
    }

    func testNeurIPSModernPDFRewriteDatasetsTrack() {
        XCTAssertEqual(rewrite("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Datasets_and_Benchmarks_Track.pdf"),
                       "https://proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Datasets_and_Benchmarks_Track.html")
    }

    func testPMLRPDFRewrite() {
        XCTAssertEqual(rewrite("https://proceedings.mlr.press/v200/foo23a/foo23a.pdf"),
                       "https://proceedings.mlr.press/v200/foo23a.html")
    }

    func testACMPDFRewrite() {
        XCTAssertEqual(rewrite("https://dl.acm.org/doi/pdf/10.1145/foo"),
                       "https://dl.acm.org/doi/10.1145/foo")
    }

    func testNaturePDFRewrite() {
        XCTAssertEqual(rewrite("https://nature.com/articles/foo.pdf"),
                       "https://nature.com/articles/foo")
    }

    func testScienceDirectPDFFTRewrite() {
        XCTAssertEqual(rewrite("https://www.sciencedirect.com/science/article/pii/SXXXX/pdfft"),
                       "https://sciencedirect.com/science/article/pii/SXXXX")
    }

    func testIEEEStampStaysAsIs() {
        // IEEE stamp.jsp PDFs have no clean landing-page mapping; pass through
        // so subsequent fetch hits the PDF endpoint and content-type check
        // rejects it (§4 row).
        XCTAssertEqual(rewrite("https://ieeexplore.ieee.org/stamp/stamp.jsp"),
                       "https://ieeexplore.ieee.org/stamp/stamp.jsp")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.PaperURLRewriteTests 2>&1 | tail -10
```

Expected: failures at the `fatalError` trap.

- [ ] **Step 3: Implement `rewritePDFURLToLanding`**

Replace the stub in `PaperURLResolver.swift`:

```swift
internal extension PaperURLResolver {
    static func rewritePDFURLToLanding(_ url: URL, host: KnownPaperHost) -> URL {
        guard let canonical = canonicalize(url),
              var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return url
        }

        let path = components.path

        switch host {
        case .openReview:
            // /pdf?id=X → /forum?id=X
            if path == "/pdf" { components.path = "/forum" }

        case .aclAnthology:
            // /2024.acl-long.123.pdf → /2024.acl-long.123/
            if path.hasSuffix(".pdf") {
                let trimmed = String(path.dropLast(4))
                components.path = trimmed + "/"
            }

        case .cvfOpenAccess:
            // /content/X/papers/Y.pdf → /content/X/html/Y.html
            if path.contains("/papers/") && path.hasSuffix(".pdf") {
                components.path = path
                    .replacingOccurrences(of: "/papers/", with: "/html/")
                    .replacingOccurrences(of: ".pdf", with: ".html")
            }

        case .neurIPS:
            // /paper/<year>/file/<file>.pdf → /paper/<year>/hash/<file>.html
            if path.contains("/file/") && path.hasSuffix(".pdf") {
                components.path = path
                    .replacingOccurrences(of: "/file/", with: "/hash/")
                    .replacingOccurrences(of: ".pdf", with: ".html")
            }

        case .neurIPSProceedings:
            // /paper_files/paper/<year>/file/<hash>-Paper<rest>.pdf
            //   → /paper_files/paper/<year>/hash/<hash>-Abstract<rest>.html
            if path.contains("/file/") && path.hasSuffix(".pdf") {
                let regex = try? NSRegularExpression(
                    pattern: #"(/paper_files/paper/\d+/)file/(.+)-Paper(.*)\.pdf$"#
                )
                let range = NSRange(path.startIndex..., in: path)
                if let match = regex?.firstMatch(in: path, options: [], range: range),
                   let r1 = Range(match.range(at: 1), in: path),
                   let r2 = Range(match.range(at: 2), in: path),
                   let r3 = Range(match.range(at: 3), in: path) {
                    components.path = "\(path[r1])hash/\(path[r2])-Abstract\(path[r3]).html"
                }
            }

        case .pmlr:
            // /v200/foo23a/foo23a.pdf → /v200/foo23a.html
            // (strip the duplicate basename segment + swap ext)
            if path.contains("/") && path.hasSuffix(".pdf") {
                let segments = path.split(separator: "/").map(String.init)
                if segments.count >= 3 {
                    let basenamePDF = segments.last ?? ""
                    let basenameLanding = basenamePDF.replacingOccurrences(of: ".pdf", with: "")
                    let prefix = "/" + segments.dropLast(2).joined(separator: "/")
                    components.path = "\(prefix)/\(basenameLanding).html"
                }
            }

        case .ieeeXplore:
            // /stamp/stamp.jsp → leave as-is (no clean landing rewrite)
            // /(document|abstract/document)/N → leave as-is (already landing)
            break

        case .acmDL:
            // /doi/pdf/10.X/Y → /doi/10.X/Y
            if path.hasPrefix("/doi/pdf/") {
                components.path = "/doi/" + String(path.dropFirst("/doi/pdf/".count))
            }

        case .nature:
            // /articles/foo.pdf → /articles/foo
            if path.hasSuffix(".pdf") {
                components.path = String(path.dropLast(4))
            }

        case .springer:
            // No PDF rewrite for Springer — KnownPaperHost.classify rejects PDF URLs.
            break

        case .scienceDirect:
            // /science/article/pii/SXXXX/pdfft → /science/article/pii/SXXXX
            if path.hasSuffix("/pdfft") {
                components.path = String(path.dropLast("/pdfft".count))
            }
        }

        return components.url ?? url
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.PaperURLRewriteTests 2>&1 | tail -20
```

Expected: all 12 rewrite tests pass.

### 3.F — Shared `fetchHTML` HTTP helper + retry

- [ ] **Step 1: Implement `fetchHTML` in `PaperURLResolver.swift`**

Replace the stub. Add this implementation at the bottom of `PaperURLResolver.swift`:

```swift
internal extension PaperURLResolver {
    static func fetchHTML(
        url: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15,
        maxAttempts: Int = 3
    ) async throws -> PaperURLHTTPResponse {
        try await withRetry(maxAttempts: maxAttempts) {
            var request = URLRequest(url: url)
            request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.timeoutInterval = timeout

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ResolveError.fetchFailed(statusCode: 0, host: url.host ?? "")
            }

            // HTTP errors → throw (withRetry decides whether to retry).
            if httpResponse.statusCode >= 400 {
                throw ResolveError.fetchFailed(statusCode: httpResponse.statusCode, host: url.host ?? "")
            }

            // Redirect-host check: response.url is the final URL after redirects.
            let finalURL = httpResponse.url ?? url
            if let finalHost = finalURL.host?.lowercased(),
               KnownPaperHost.classify(finalURL) == nil {
                throw ResolveError.redirectedAwayFromAllowlist(finalHost: finalHost)
            }

            // Content-type policy: accept text/html, application/xhtml+xml, or missing.
            let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !contentType.isEmpty
                && !contentType.hasPrefix("text/html")
                && !contentType.hasPrefix("application/xhtml+xml") {
                throw ResolveError.unexpectedContentType(contentType)
            }

            return PaperURLHTTPResponse(data: data, finalURL: finalURL, contentType: contentType.isEmpty ? nil : contentType)
        }
    }

    private static func userAgent() -> String {
        let email = MetadataFetcher.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.isEmpty || !email.contains("@") {
            return "Rubien/1.0"
        }
        return "Rubien/1.0 (mailto:\(email))"
    }

    /// Retry contract (matches CitationMetaScraper §2.1):
    /// - URLError.timedOut: retry with 1s base, exponential
    /// - URLError.networkConnectionLost: retry with 1s base, exponential
    /// - ResolveError.fetchFailed with status 5xx: retry with 1s base
    /// - ResolveError.fetchFailed with status 429: retry with 3s base
    /// - Everything else: throw immediately (no retry)
    private static func withRetry<T>(
        maxAttempts: Int,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch let error as ResolveError {
                guard case .fetchFailed(let statusCode, _) = error,
                      statusCode == 429 || (500...599).contains(statusCode) else {
                    throw error  // Non-retryable HTTP error (4xx other than 429, etc.)
                }
                lastError = error
                let base: UInt64 = statusCode == 429 ? 3_000_000_000 : 1_000_000_000
                let delay = base * UInt64(1 << attempt)
                try await Task.sleep(nanoseconds: delay)
            } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                lastError = error
                let delay: UInt64 = 1_000_000_000 * UInt64(1 << attempt)
                try await Task.sleep(nanoseconds: delay)
            } catch {
                throw error
            }
        }
        throw lastError ?? ResolveError.fetchFailed(statusCode: -1, host: "")
    }
}
```

- [ ] **Step 2: Confirm build**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build 2>&1 | tail -10
```

Expected: success.

### 3.G — `PaperURLResolver.resolve` orchestrator (TDD)

- [ ] **Step 1: Write failing tests against the orchestrator**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/PaperURLResolverTests.swift`:

```swift
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLProtocol, URLSessionConfiguration, HTTPURLResponse
#endif
@testable import RubienCore

/// URLProtocol-based stub for injecting fake HTTP responses.
/// Static state is reset in setUp + tearDown to prevent cross-test leakage.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubs: [URL: (data: Data, response: HTTPURLResponse)] = [:]
    nonisolated(unsafe) static var failures: [URL: Error] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let err = StubURLProtocol.failures[url] {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        if let stub = StubURLProtocol.stubs[url] {
            client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
    }

    override func stopLoading() {}

    static func reset() {
        stubs = [:]
        failures = [:]
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func stub(_ urlString: String, status: Int = 200, contentType: String = "text/html", body: String) {
        let url = URL(string: urlString)!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        stubs[url] = (body.data(using: .utf8)!, response)
    }
}

final class PaperURLResolverTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: "CitationMeta/\(name)", withExtension: "html")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - OpenReview success path (no DOI)

    func testOpenReviewLandingProducesConferencePaper() async throws {
        StubURLProtocol.stub(
            "https://openreview.net/forum?id=EXAMPLE",
            body: loadFixture("openreview-forum")
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://openreview.net/forum?id=EXAMPLE")!,
            session: StubURLProtocol.makeSession()
        )

        XCTAssertEqual(outcome.reference.title, "Attention Is All You Need")
        XCTAssertEqual(outcome.reference.referenceType, .conferencePaper)
        XCTAssertEqual(outcome.reference.metadataSource, .publisherCitationMeta)
        XCTAssertEqual(outcome.reference.url, "https://openreview.net/forum?id=EXAMPLE")
        XCTAssertEqual(outcome.scrapedPDFURL, "https://openreview.net/pdf?id=EXAMPLE")
    }

    // MARK: - Content-Type rejection

    func testNonHTMLContentTypeRejected() async {
        StubURLProtocol.stub(
            "https://openreview.net/forum?id=EXAMPLE",
            contentType: "application/pdf",
            body: ""
        )

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://openreview.net/forum?id=EXAMPLE")!,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected unexpectedContentType")
        } catch PaperURLResolver.ResolveError.unexpectedContentType {
            // expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Strong evidence gate (paywall)

    func testInsufficientCitationMetaRejected() async {
        StubURLProtocol.stub(
            "https://www.sciencedirect.com/science/article/pii/SXXXX",
            body: loadFixture("paywall-login-page")
        )

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://www.sciencedirect.com/science/article/pii/SXXXX")!,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected insufficientMetadata")
        } catch PaperURLResolver.ResolveError.insufficientMetadata {
            // expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - CVF BibTeX path

    func testCVFLandingExtractsFromBibTeX() async throws {
        StubURLProtocol.stub(
            "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html",
            body: loadFixture("cvf-paper")
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html")!,
            session: StubURLProtocol.makeSession()
        )

        XCTAssertEqual(outcome.reference.title, "A Sample CVPR Paper")
        XCTAssertEqual(outcome.reference.referenceType, .conferencePaper)
        XCTAssertEqual(outcome.reference.metadataSource, .cvfOpenAccess)
        XCTAssertEqual(outcome.reference.authors.count, 2)
        XCTAssertEqual(outcome.scrapedPDFURL, "https://openaccess.thecvf.com/content/CVPR2024/papers/Foo_paper.pdf")
    }

    // MARK: - Canonical Reference.url after canonicalization

    func testCanonicalURLOnReference() async throws {
        StubURLProtocol.stub(
            "https://nature.com/articles/foo",
            body: """
            <html><head>
            <meta name="citation_title" content="Nature Paper">
            <meta name="citation_author" content="Smith, J.">
            <meta name="citation_journal_title" content="Nature">
            <meta name="citation_publication_date" content="2024">
            </head></html>
            """
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "HTTPS://WWW.NATURE.COM/articles/foo")!,
            session: StubURLProtocol.makeSession()
        )

        // Canonical: lowercase scheme + host, no www.
        XCTAssertEqual(outcome.reference.url, "https://nature.com/articles/foo")
    }

    // MARK: - No-author safeguard

    func testNoAuthorsReturnsCandidate() async {
        // Hypothetical: citation_title + citation_doi only, no citation_author.
        // CrossRef stub will also fail (no stub registered for crossref endpoint).
        StubURLProtocol.stub(
            "https://ieeexplore.ieee.org/document/1234",
            body: """
            <html><head>
            <meta name="citation_title" content="IEEE Doc Without Authors">
            <meta name="citation_doi" content="10.1109/foo.bar.99999999">
            <meta name="citation_publication_date" content="2024">
            </head></html>
            """
        )

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://ieeexplore.ieee.org/document/1234")!,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected noAuthorsAvailable")
        } catch PaperURLResolver.ResolveError.noAuthorsAvailable(let partialRef, _) {
            // Verify the payload carries the partial Reference so the caller
            // can build a CandidateEnvelope from it.
            XCTAssertEqual(partialRef.title, "IEEE Doc Without Authors")
            XCTAssertEqual(partialRef.doi, "10.1109/foo.bar.99999999")
            XCTAssertTrue(partialRef.authors.isEmpty)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - HTTP 503 retried

    func testHTTPServerErrorRetries() async throws {
        // First request 503, second 200 — needs a counter-based stub.
        // Use a custom URLProtocol subclass for this test:
        final class CountingStub: URLProtocol {
            nonisolated(unsafe) static var attemptCount = 0
            nonisolated(unsafe) static var html = ""
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.attemptCount += 1
                let url = request.url!
                if Self.attemptCount == 1 {
                    let r = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
                    client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocolDidFinishLoading(self)
                } else {
                    let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
                    client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Self.html.data(using: .utf8)!)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        CountingStub.attemptCount = 0
        CountingStub.html = loadFixture("openreview-forum")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingStub.self]
        let session = URLSession(configuration: config)

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://openreview.net/forum?id=EXAMPLE")!,
            session: session
        )
        XCTAssertEqual(CountingStub.attemptCount, 2)
        XCTAssertEqual(outcome.reference.title, "Attention Is All You Need")
    }

    // MARK: - HTTP 404 does not retry

    func testHTTP404DoesNotRetry() async {
        StubURLProtocol.stub("https://openreview.net/forum?id=DEAD", status: 404, body: "")

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://openreview.net/forum?id=DEAD")!,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected fetchFailed")
        } catch PaperURLResolver.ResolveError.fetchFailed(let status, _) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.PaperURLResolverTests 2>&1 | tail -20
```

Expected: failures at `fatalError("not yet implemented")` in `PaperURLResolver.resolve`.

- [ ] **Step 3: Implement `PaperURLResolver.resolve`**

Replace the `resolve` stub. Add this at the appropriate location in `PaperURLResolver.swift`:

```swift
public enum PaperURLResolver {
    // ... existing Outcome struct + ResolveError enum kept ...

    public static func resolve(
        _ url: URL,
        session: URLSession = .shared
    ) async throws -> Outcome {
        // 1. Canonicalize.
        guard let canonical = canonicalize(url) else {
            throw ResolveError.unsupportedScheme
        }

        // 2. Classify.
        guard let host = KnownPaperHost.classify(canonical) else {
            throw ResolveError.unknownHost
        }

        // 3. Rewrite PDF URL → landing URL if applicable.
        let landingURL = rewritePDFURLToLanding(canonical, host: host)

        // 4. Dispatch to host-specific adapter.
        let (scrapedReference, scrapedPDFURL): (Reference, String?)
        if host == .cvfOpenAccess {
            (scrapedReference, scrapedPDFURL) = try await resolveCVF(landingURL: landingURL, session: session)
        } else {
            (scrapedReference, scrapedPDFURL) = try await resolveCitationMeta(landingURL: landingURL, host: host, session: session)
        }

        // 5. If DOI present, re-fetch via CrossRef.
        var finalReference = scrapedReference
        if let doi = scrapedReference.doi?.trimmingCharacters(in: .whitespacesAndNewlines),
           !doi.isEmpty {
            do {
                let crossref = try await MetadataFetcher.fetchFromDOI(doi)
                let scraperTitle = scrapedReference.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let crossrefTitle = crossref.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let score = MetadataResolution.titleSimilarity(scraperTitle, crossrefTitle)
                if score >= 0.80 {
                    finalReference = MetadataResolution.mergeReference(primary: crossref, fallback: scrapedReference)
                    // Force canonical landing URL — CrossRef may have populated url with doi.org redirect.
                    finalReference.url = landingURL.absoluteString
                    // Keep metadataSource as publisherCitationMeta (the user pasted a publisher URL,
                    // not just a DOI; provenance should reflect that path).
                    finalReference.metadataSource = scrapedReference.metadataSource
                } else {
                    // Title mismatch (chapter-vs-book scenario) — keep scraper-only.
                    // Log via existing logger if available; spec uses resolverTrace which lives in
                    // the resolver layer; here we silently keep the scraper-only Reference.
                }
            } catch {
                // CrossRef failure is non-fatal — keep scraper-only Reference.
            }
        }

        // 6. No-author safeguard. Throw with payload so the caller can build
        // a CandidateEnvelope from the partial Reference (spec §4 requires
        // .candidate, not .rejected).
        if finalReference.authors.isEmpty {
            throw ResolveError.noAuthorsAvailable(
                reference: finalReference,
                scrapedPDFURL: scrapedPDFURL
            )
        }

        return Outcome(reference: finalReference, scrapedPDFURL: scrapedPDFURL)
    }

    // MARK: - Citation-meta dispatch

    private static func resolveCitationMeta(
        landingURL: URL,
        host: KnownPaperHost,
        session: URLSession
    ) async throws -> (Reference, String?) {
        let meta = try await CitationMetaScraper.fetch(landingURL, session: session)

        // Strong evidence gate: require citation_title + at least 1 other.
        guard let title = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw ResolveError.insufficientMetadata
        }
        let hasOtherEvidence = !meta.authors.isEmpty
            || (meta.doi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || meta.year != nil
            || (meta.journal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (meta.conferenceTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        guard hasOtherEvidence else {
            throw ResolveError.insufficientMetadata
        }

        let referenceType: ReferenceType = {
            switch host {
            case .cvfOpenAccess, .neurIPS, .neurIPSProceedings, .pmlr:
                return .conferencePaper
            case .openReview:
                return .conferencePaper
            case .aclAnthology:
                return meta.conferenceTitle != nil ? .conferencePaper : .journalArticle
            case .ieeeXplore, .acmDL, .nature, .springer, .scienceDirect:
                if meta.journal != nil { return .journalArticle }
                if meta.conferenceTitle != nil { return .conferencePaper }
                return .journalArticle
            }
        }()

        let pages: String? = {
            if let first = meta.firstPage, let last = meta.lastPage { return "\(first)-\(last)" }
            return meta.firstPage
        }()

        let ref = Reference(
            title: title,
            authors: meta.authors,
            year: meta.year,
            journal: meta.journal ?? meta.conferenceTitle,
            volume: meta.volume,
            issue: meta.issue,
            pages: pages,
            doi: meta.doi,
            url: landingURL.absoluteString,
            abstract: meta.abstract,
            referenceType: referenceType,
            metadataSource: .publisherCitationMeta,
            publisher: meta.publisher,
            isbn: meta.isbn,
            issn: meta.issn,
            eventTitle: (referenceType == .conferencePaper) ? meta.conferenceTitle : nil
        )
        return (ref, meta.pdfURL)
    }

    // MARK: - CVF BibTeX dispatch

    private static func resolveCVF(
        landingURL: URL,
        session: URLSession
    ) async throws -> (Reference, String?) {
        let response = try await fetchHTML(url: landingURL, session: session)
        let html = String(data: response.data, encoding: .utf8) ?? ""

        // Extract <pre>...</pre> contents.
        let pattern = #"(?s)<pre[^>]*>(.+?)</pre>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw ResolveError.bibtexNotFound
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let bibRange = Range(match.range(at: 1), in: html) else {
            throw ResolveError.bibtexNotFound
        }
        let bibtex = String(html[bibRange])

        let refs = BibTeXImporter.parse(bibtex)
        guard let first = refs.first,
              !first.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResolveError.bibtexEmpty
        }

        // Synthesize PDF URL from landing URL.
        let pdfURL = landingURL.absoluteString
            .replacingOccurrences(of: "/html/", with: "/papers/")
            .replacingOccurrences(of: ".html", with: ".pdf")

        var ref = first
        ref.url = landingURL.absoluteString
        ref.metadataSource = .cvfOpenAccess
        ref.referenceType = .conferencePaper

        return (ref, pdfURL)
    }
}
```

- [ ] **Step 4: Run resolver tests to confirm pass**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.PaperURLResolverTests 2>&1 | tail -30
```

Expected: all tests pass. If `testHTTPServerErrorRetries` takes >5s (real sleep between retries), consider lowering the retry delay in test mode — but in practice 1 second + ~1 second sleep is acceptable.

### 3.H — Full build + all-tests sanity

- [ ] **Step 1: Run full test suite**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build 2>&1 | tail -10 && swift test 2>&1 | tail -20
```

Expected: build succeeds, all tests pass (including the previously-existing ones).

### 3.I — Commit Task 3

- [ ] **Step 1: Commit the bundled work**

```bash
cd /Users/hzzheng/CodeHub/Rubien
git add Sources/RubienCore/Services/CitationMetaScraper.swift \
        Sources/RubienCore/Services/PaperURLResolver.swift \
        Tests/RubienCoreTests/CitationMetaScraperParseTests.swift \
        Tests/RubienCoreTests/KnownPaperHostClassifyTests.swift \
        Tests/RubienCoreTests/PaperURLRewriteTests.swift \
        Tests/RubienCoreTests/PaperURLResolverTests.swift \
        Tests/RubienCoreTests/Fixtures \
        Package.swift
git commit -m "$(cat <<'EOF'
RubienCore: paper-URL resolver + citation-meta scraper

Adds PaperURLResolver (orchestrator) and CitationMetaScraper (generic
<meta name="citation_*"> parser). Bundled because the scraper's
redirect-host check references KnownPaperHost, and both adapters
share fetchHTML, both defined in PaperURLResolver.

Coverage:
- 10 known paper hosts (OpenReview, ACL, CVF, NeurIPS legacy + modern,
  PMLR, IEEE, ACM, Nature, Springer, ScienceDirect)
- Host + path-shape classification (Springer search pages and IEEE
  journal homepages correctly fall through)
- URL canonicalization (lowercase scheme/host, strip www., strip
  fragment + default ports, preserve path/query)
- PDF-URL → landing-page rewrite per host (NeurIPS regex covers
  track variants; Springer PDFs intentionally not rewritten)
- DOI re-fetch via existing MetadataFetcher.fetchFromDOI with 0.80
  title-similarity guard against chapter-vs-book mismatch
- CVF BibTeX adapter reusing BibTeXImporter.parse
- Strong evidence gate (citation_title + 1 other tag required)
- No-author safeguard returns ResolveError.noAuthorsAvailable
- Retry on URLError.timedOut / networkConnectionLost / HTTP 5xx / 429
- Content-type filter accepts text/html / xhtml / missing; rejects pdf
- Redirect-to-unrelated-host check via final URL against allowlist

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: MetadataFetcher.Identifier.paperURL + extractIdentifier + resolveIdentifierLocally tuple

**Files:**
- Modify: `Sources/RubienCore/Services/MetadataFetcher.swift` (Identifier enum, extractIdentifier, fetch(from:) switch — note function name is `fetch(from:)`, not `fetch(identifier:)`).
- Modify: `Sources/Rubien/Services/MetadataResolver.swift` (Mac-only file at `Sources/Rubien/Services/`, NOT under RubienCore). Changes: `resolveIdentifierLocally` return type to tuple + `.paperURL` branch + no-author catch that builds a CandidateEnvelope.
- Create: `Tests/RubienCoreTests/PaperURLExtractionTests.swift`

**Why bundled:** Adding `.paperURL` to the enum without updating switch consumers breaks the build. Atomic commit.

**Important — CLI integration.** The CLI (`Sources/RubienCLI/RubienCLI.swift:649`) calls `MetadataFetcher.fetch(from:)` directly, not `MetadataResolver`. To preserve CLI behavior for paper URLs, the `.paperURL` arm of `fetch(from:)` must call `PaperURLResolver.resolve(url)` and return `outcome.reference`. The CLI does not need `preferredPDFURL` (it never auto-downloads from a URL); it just needs the `Reference`. The richer `.candidate` / `ManualEntryOutcome` plumbing lives in `MetadataResolver.resolveManualEntry` (Task 5), which is the Mac app's path.

- [ ] **Step 1: Write the failing extraction tests**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/PaperURLExtractionTests.swift`:

```swift
import XCTest
@testable import RubienCore

final class PaperURLExtractionTests: XCTestCase {

    private func extract(_ s: String) -> MetadataFetcher.Identifier? {
        MetadataFetcher.extractIdentifier(from: s)
    }

    func testOpenReviewForumExtractsAsPaperURL() {
        guard case .paperURL = extract("https://openreview.net/forum?id=ABCD") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testOpenReviewPDFExtractsAsPaperURL() {
        guard case .paperURL = extract("https://openreview.net/pdf?id=ABCD") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testACLExtractsAsPaperURL() {
        guard case .paperURL = extract("https://aclanthology.org/2024.acl-long.123/") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testNatureExtractsAsPaperURL() {
        guard case .paperURL = extract("https://www.nature.com/articles/s41586-024-12345-6") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testSpringerArticleExtractsAsPaperURL() {
        guard case .paperURL = extract("https://link.springer.com/article/10.1007/s11042-024-12345-6") else {
            return XCTFail("Expected .paperURL — must beat bare DOI extraction")
        }
    }

    func testSpringerChapterExtractsAsPaperURL() {
        guard case .paperURL = extract("https://link.springer.com/chapter/10.1007/978-3-540-24777-7_1") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testSpringerContentPDFNotAccepted() {
        // No Springer PDF rewrite — must fall through.
        let result = extract("https://link.springer.com/content/pdf/10.1007/foo.pdf")
        switch result {
        case .paperURL: XCTFail("Should not be .paperURL")
        case .doi: break  // OK — bare DOI substring caught by existing extractor
        case .none: break // OK — no identifier
        default: XCTFail("Unexpected: \(String(describing: result))")
        }
    }

    func testSpringerSearchFallsThrough() {
        XCTAssertNil(extract("https://link.springer.com/search?q=neural"))
    }

    func testRandomBlogFallsThrough() {
        XCTAssertNil(extract("https://example-blog.com/post/hello"))
    }

    func testBareDOIStillWorks() {
        guard case .doi(let value) = extract("10.1234/abc.def"),
              value == "10.1234/abc.def" else {
            return XCTFail("Bare DOI extraction broken")
        }
    }

    func testCaseInsensitivePaperURL() {
        guard case .paperURL = extract("HTTPS://WWW.NATURE.COM/articles/foo") else {
            return XCTFail("Expected .paperURL after canonicalization")
        }
    }
}
```

- [ ] **Step 2: Verify tests fail with "no such case .paperURL"**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.PaperURLExtractionTests 2>&1 | tail -15
```

Expected: build error: `type 'MetadataFetcher.Identifier' has no case named 'paperURL'`.

- [ ] **Step 3: Add `.paperURL(URL)` case to `Identifier`**

Edit `/Users/hzzheng/CodeHub/Rubien/Sources/RubienCore/Services/MetadataFetcher.swift`. Find the `Identifier` enum (around line 59) and add the new case:

```swift
public enum Identifier: Equatable {
    case doi(String)
    case pmid(String)
    case arxiv(String)
    case isbn(String)
    case pmcid(String)
    case paperURL(URL)   // NEW: paper landing-page URL routed via PaperURLResolver
}
```

- [ ] **Step 4: Update `extractIdentifier` to detect paper URLs first**

In `extractIdentifier` (around line 68), add the paper-URL check before the existing PMCID/DOI/arXiv checks. Inside the function, near the top after `trimmed` is computed:

```swift
// NEW: paper landing-page URL on a known host with a known path shape.
// Placed before DOI extraction so URLs like
//   https://link.springer.com/article/10.1007/s11042-024-12345-6
// route through PaperURLResolver (preserves landing URL on Reference.url)
// rather than the bare DOI extractor (which would route to CrossRef and
// lose publisher-page context).
if let url = URL(string: trimmed),
   let scheme = url.scheme?.lowercased(),
   (scheme == "http" || scheme == "https"),
   KnownPaperHost.classify(url) != nil {
    return .paperURL(url)
}
```

- [ ] **Step 5: Update the `MetadataFetcher.fetch(from:)` switch (around line 1093) for exhaustiveness AND CLI routing**

Find the switch in `fetch(from:)`. It currently has 5 arms; add a 6th that routes through `PaperURLResolver.resolve` so the CLI (which calls `fetch(from:)` directly at `RubienCLI.swift:649`) keeps working for paper URLs:

```swift
switch identifier {
case .doi(let doi):       return try await fetchFromDOI(doi)
case .pmid(let pmid):     return try await fetchFromPMID(pmid)
case .arxiv(let id):      return try await fetchFromArXiv(id)
case .isbn(let isbn):     return try await fetchFromISBN(isbn)
case .pmcid(let pmcid):   return try await fetchFromPMCID(pmcid)
case .paperURL(let url):
    // Route paper URLs through PaperURLResolver so the CLI (which calls
    // fetch(from:) directly at RubienCLI.swift:649) gets a Reference back.
    // The CLI does not use ManualEntryOutcome / preferredPDFURL — it just
    // needs the Reference.
    do {
        let outcome = try await PaperURLResolver.resolve(url)
        return outcome.reference
    } catch PaperURLResolver.ResolveError.noAuthorsAvailable {
        // CLI has no candidate-review channel. Throwing here is the right
        // call — silently importing a no-author Reference via fetch(from:)
        // would save a half-baked record (the schema accepts empty authors
        // as TEXT NOT NULL DEFAULT "", so nothing rejects it downstream).
        // The Mac app gets the .candidate path via MetadataResolver's catch
        // handler in resolveIdentifierLocally; the CLI gets an error.
        throw FetchError.unsupported(
            "Paper URL resolved but no authors were found. Review the page or paste a DOI."
        )
    } catch let error as PaperURLResolver.ResolveError {
        throw FetchError.unsupported(String(describing: error))
    }
}
```

- [ ] **Step 6: Run extraction tests to verify they pass**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienCoreTests.PaperURLExtractionTests 2>&1 | tail -15
```

Expected: all extraction tests pass.

- [ ] **Step 7: Update `resolveIdentifierLocally` return type**

Edit `/Users/hzzheng/CodeHub/Rubien/Sources/Rubien/Services/MetadataResolver.swift`. Find `resolveIdentifierLocally` (around line 369) and:

(a) change return type to a tuple, (b) add the `.paperURL` branch:

```swift
private func resolveIdentifierLocally(
    _ identifier: MetadataFetcher.Identifier,
    seed: MetadataResolutionSeed?,
    fallback: Reference?
) async -> (MetadataResolutionResult, scrapedPDFURL: String?) {
    do {
        let reference: Reference
        var scrapedPDFURL: String? = nil
        switch identifier {
        case .doi(let value):
            reference = try await MetadataFetcher.fetchFromDOI(value)
        case .pmid(let value):
            reference = try await MetadataFetcher.fetchFromPMID(value)
        case .arxiv(let value):
            reference = try await MetadataFetcher.fetchFromArXiv(value)
        case .isbn(let value):
            reference = try await MetadataFetcher.fetchFromISBN(value)
        case .pmcid(let value):
            reference = try await MetadataFetcher.fetchFromPMCID(value)
        case .paperURL(let url):
            let outcome = try await PaperURLResolver.resolve(url)
            reference = outcome.reference
            scrapedPDFURL = outcome.scrapedPDFURL
        }

        let evidence = buildGenericEvidence(
            for: reference,
            fetchMode: .identifier,
            origin: .identifierAPI,
            recordKey: normalizedIdentifier(reference.doi)
                ?? normalizedIdentifier(reference.pmid)
                ?? normalizedIdentifier(reference.isbn),
            exactIdentifierMatch: true
        )
        let result = verifyFetchedRecord(
            AuthoritativeMetadataRecord(reference: reference, evidence: evidence),
            seed: seed,
            fallback: fallback,
            defaultRejectMessage: "Identifier matched, but auto-verification rules were not met."
        )

        // Force scrapedPDFURL to nil on any non-verified outcome — preferredPDFURL
        // is defined as "populated only on .verified". See ManualEntryOutcome.
        let effectiveScrapedPDFURL: String? = {
            if case .verified = result { return scrapedPDFURL }
            return nil
        }()
        return (result, effectiveScrapedPDFURL)
    } catch PaperURLResolver.ResolveError.noAuthorsAvailable(let partialRef, _) {
        // Spec §4: empty Reference.authors produces .candidate (NOT .rejected),
        // so the user reviews the partial metadata before importing. Build a
        // single-element MetadataCandidate from the scraped Reference.
        // scrapedPDFURL is intentionally discarded — preferredPDFURL is
        // .verified-only.
        resolverTrace("resolveIdentifierLocally noAuthorsAvailable: title=\(partialRef.title)")
        let candidate = MetadataCandidate(
            source: partialRef.metadataSource ?? .publisherCitationMeta,
            title: partialRef.title,
            authors: partialRef.authors,
            journal: partialRef.journal,
            publisher: partialRef.publisher,
            year: partialRef.year,
            detailURL: partialRef.url ?? "",
            // Score is 1.0 — direct-source URL, no competing candidates, single
            // entry list. The user is reviewing because authors are missing,
            // not because of low confidence in the match. Picking < global
            // candidateThreshold (0.52) here would render as a misleading
            // "50% match" in the UI.
            score: 1.0,
            snippet: partialRef.abstract,
            workKind: .unknown,
            referenceType: partialRef.referenceType,
            isbn: partialRef.isbn,
            issn: partialRef.issn,
            sourceRecordID: partialRef.doi
        )
        return (.candidate(
            CandidateEnvelope(
                seed: seed,
                fallbackReference: fallback,
                currentReference: partialRef,
                candidates: [candidate],
                message: "Found a paper, but no authors are listed on the page or in CrossRef. Review before importing.",
                evidence: nil
            )
        ), nil)
    } catch {
        resolverTrace("resolveIdentifierLocally failed error=\"\(error.localizedDescription)\"")
        return (.rejected(
            RejectedEnvelope(
                seed: seed,
                fallbackReference: fallback,
                currentReference: fallback,
                reason: .insufficientEvidence,
                message: error.localizedDescription
            )
        ), nil)
    }
}
```

**Important — verify `CandidateEnvelope` initializer signature.** The plan above uses the labels `(seed:fallbackReference:currentReference:candidates:message:evidence:)`. If the actual initializer at `Sources/RubienCore/Models/MetadataVerification.swift` (around line 262) differs, adjust the call. Run `grep -n "public init" Sources/RubienCore/Models/MetadataVerification.swift` and inspect the `CandidateEnvelope` initializer.

- [ ] **Step 8: Update callers of `resolveIdentifierLocally` inside `MetadataResolver.swift`**

Find all calls to `resolveIdentifierLocally(` in `MetadataResolver.swift` (use `grep -n "resolveIdentifierLocally(" Sources/Rubien/Services/MetadataResolver.swift`). At each call site, change:

```swift
let result = await resolveIdentifierLocally(...)
```

to:

```swift
let (result, _) = await resolveIdentifierLocally(...)
```

— **EXCEPT** the call from inside `resolveManualEntry`, which will be updated in Task 5 to use the URL. Leave that call's `(result, _)` form as a placeholder for now; Task 5 changes it.

- [ ] **Step 9: Build the entire project**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build 2>&1 | tail -20
```

Expected: clean build. If there are exhaustiveness warnings for other switches over `Identifier`, address them (most likely sites: tests or display code).

- [ ] **Step 10: Run full test suite**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test 2>&1 | tail -15
```

Expected: all tests pass.

- [ ] **Step 11: Commit Task 4**

```bash
cd /Users/hzzheng/CodeHub/Rubien
git add Sources/RubienCore/Services/MetadataFetcher.swift \
        Sources/Rubien/Services/MetadataResolver.swift \
        Tests/RubienCoreTests/PaperURLExtractionTests.swift
git commit -m "$(cat <<'EOF'
RubienCore + Rubien: route paper URLs through PaperURLResolver

Adds MetadataFetcher.Identifier.paperURL(URL) case and the matching
extractIdentifier branch. Path-shape classification beats bare-DOI
extraction so Springer/ACM URLs preserve their landing-page on
Reference.url instead of resolving to a doi.org redirect.

MetadataResolver.resolveIdentifierLocally now returns a tuple
(MetadataResolutionResult, scrapedPDFURL: String?). Five existing
branches return nil scrapedPDFURL; new .paperURL branch surfaces
the scraped PDF URL on .verified outcomes only (forced to nil
on any non-verified result per spec).

No-author safeguard: PaperURLResolver.ResolveError.noAuthorsAvailable
carries a (Reference, scrapedPDFURL: String?) payload. The catch
handler in MetadataResolver.resolveIdentifierLocally converts the
throw into a .candidate result with a single-element
[MetadataCandidate] built from the partial Reference, so the user
reviews the no-author record rather than auto-importing it. The
CLI path (MetadataFetcher.fetch(from:)) re-throws as
FetchError.unsupported — CLI has no candidate-review channel.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: ManualEntryOutcome wrapper

**Files:**
- Modify: `Sources/Rubien/Services/MetadataResolver.swift` — define `ManualEntryOutcome`, change `resolveManualEntry` signature.
- Modify: `Sources/Rubien/Views/AddByIdentifierView.swift` — consume `.result` from wrapper.
- Modify: `Sources/Rubien/Views/BatchImportView.swift` — consume `.result` (ignore `preferredPDFURL`).
- Create: `Tests/RubienCoreTests/MetadataResolverPaperURLTests.swift`

- [ ] **Step 1: Add `ManualEntryOutcome` struct + change signature**

Edit `Sources/Rubien/Services/MetadataResolver.swift`. Above the `MetadataResolver` class declaration, add:

```swift
public struct ManualEntryOutcome: Sendable {
    public let result: MetadataResolutionResult
    public let preferredPDFURL: String?    // populated only on .verified from paper-URL path

    public init(result: MetadataResolutionResult, preferredPDFURL: String? = nil) {
        self.result = result
        self.preferredPDFURL = preferredPDFURL
    }
}
```

Then change `resolveManualEntry` signature and body:

```swift
func resolveManualEntry(_ text: String) async -> ManualEntryOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return ManualEntryOutcome(result: .rejected(
            RejectedEnvelope(
                seed: nil,
                fallbackReference: nil,
                reason: .unsupportedRoute,
                message: "Enter a DOI, arXiv ID, PMID, PMCID, ISBN, paper URL, or paper title."
            )
        ))
    }

    if let identifier = MetadataFetcher.extractIdentifier(from: trimmed) {
        let (result, scrapedPDFURL) = await resolveIdentifierLocally(identifier, seed: nil, fallback: nil)
        return ManualEntryOutcome(result: result, preferredPDFURL: scrapedPDFURL)
    }

    // Treat remaining input as a title search.
    let seed = MetadataResolutionSeed(
        fileName: trimmed,
        title: trimmed,
        workKindHint: .unknown
    )
    if let titleResult = await resolveByTitle(trimmed, seed: seed, fallback: nil) {
        return ManualEntryOutcome(result: titleResult)
    }
    return ManualEntryOutcome(result: .rejected(
        RejectedEnvelope(
            seed: seed,
            fallbackReference: nil,
            currentReference: nil,
            reason: .insufficientEvidence,
            message: "No matching record found. Try a DOI, arXiv ID, PMID, PMCID, paper URL, or ISBN instead."
        )
    ))
}
```

Also update the placeholder caption in any localizable string referenced as `addByIdentifier.field.placeholder` to include "paper URL" (done in Task 6).

- [ ] **Step 2: Update `AddByIdentifierView` to consume the wrapper**

Edit `/Users/hzzheng/CodeHub/Rubien/Sources/Rubien/Views/AddByIdentifierView.swift`. Around line 199-209, change:

```swift
let result = await resolver.resolveManualEntry(text)
switch result {
case .verified(let envelope):
    fetchedReference = envelope.reference
case .candidate, .blocked, .seedOnly, .rejected:
    pendingResolution = result
}
```

to:

```swift
let outcome = await resolver.resolveManualEntry(text)
preferredPDFURL = outcome.preferredPDFURL
switch outcome.result {
case .verified(let envelope):
    fetchedReference = envelope.reference
case .candidate, .blocked, .seedOnly, .rejected:
    pendingResolution = outcome.result
}
```

And add a `@State private var preferredPDFURL: String?` near the other `@State` properties at the top of the view.

- [ ] **Step 3: Update `BatchImportView` calls**

Edit `/Users/hzzheng/CodeHub/Rubien/Sources/Rubien/Views/BatchImportView.swift`. At lines ~230 and ~252, change:

```swift
let result = await resolver.resolveManualEntry(identifier)
```

to:

```swift
let outcome = await resolver.resolveManualEntry(identifier)
let result = outcome.result
// Note: outcome.preferredPDFURL is intentionally discarded — batch import
// doesn't auto-download URL-derived PDFs.
```

(Verify both call sites are updated; subsequent switch statements consuming `result` need no change.)

- [ ] **Step 4: Update `MetadataResolver.retryIntake`**

Find `retryIntake` (around line 188) and update the `resolveManualEntry` call:

```swift
if let originalInput = intake.originalInput?.rubien_nilIfBlank {
    let outcome = await resolveManualEntry(originalInput)
    return outcome.result
}
```

- [ ] **Step 5: Write integration tests**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/MetadataResolverPaperURLTests.swift`:

*(Note: these tests live in `RubienCoreTests` but exercise the Mac-only `MetadataResolver`. They use `#if os(macOS)` for the body. If RubienCoreTests cannot import `Rubien`, move this file to `Tests/RubienTests/` instead and gate with `#if os(macOS)`.)*

```swift
#if os(macOS)
import XCTest
@testable import RubienCore
@testable import Rubien

@MainActor
final class MetadataResolverPaperURLTests: XCTestCase {

    // These integration tests rely on the resolver's URLSession singletons. For now,
    // verify the contract on the easy paths (rejected on malformed inputs etc.) and
    // defer full stubbing to PaperURLResolverTests which already covers the network
    // behavior. End-to-end integration with a stubbed session would require
    // dependency injection into MetadataResolver — out of scope for this task.

    func testEmptyInputRejected() async {
        let resolver = MetadataResolver()
        let outcome = await resolver.resolveManualEntry("")
        XCTAssertNil(outcome.preferredPDFURL)
        if case .rejected = outcome.result { /* ok */ } else { XCTFail("Expected .rejected") }
    }

    func testBareDOIStillWorks() async throws {
        // Network-dependent; skip in CI by default.
        try XCTSkipIf(ProcessInfo.processInfo.environment["RUBIEN_LIVE_TESTS"] != "1",
                       "Set RUBIEN_LIVE_TESTS=1 to run")
        let resolver = MetadataResolver()
        let outcome = await resolver.resolveManualEntry("10.18653/v1/2024.acl-long.123")
        XCTAssertNil(outcome.preferredPDFURL)  // bare DOI path doesn't yield a scraped URL
        switch outcome.result {
        case .verified, .candidate: break
        default: XCTFail("Expected .verified or .candidate, got \(outcome.result)")
        }
    }

    func testPreferredPDFURLNilOnNonVerified() async {
        let resolver = MetadataResolver()
        // Use a paper URL that will fail (no matching stub / DNS error etc.)
        let outcome = await resolver.resolveManualEntry("https://openreview.net/forum?id=DOES-NOT-EXIST-9999")
        XCTAssertNil(outcome.preferredPDFURL,
                     "preferredPDFURL must be nil for non-.verified outcomes")
    }

    /// Integration test: PaperURLResolver throws .noAuthorsAvailable, and the
    /// catch handler in MetadataResolver.resolveIdentifierLocally converts the
    /// throw into a .candidate result with a single-element [MetadataCandidate].
    ///
    /// This requires injecting a stubbed URLSession into PaperURLResolver's
    /// call chain. Since PaperURLResolver.resolve accepts a session parameter
    /// (default .shared), the test needs MetadataResolver to forward an
    /// injected session — which it does NOT currently do. Two ways to land
    /// this test:
    ///
    /// (a) Refactor MetadataResolver to accept an injectable URLSession on
    ///     init or on resolveManualEntry. Modest API change.
    /// (b) Move this test to the PaperURLResolver layer: call
    ///     PaperURLResolver.resolve directly with the stubbed session, catch
    ///     ResolveError.noAuthorsAvailable, then construct the expected
    ///     CandidateEnvelope inline and verify the conversion logic via a
    ///     small helper extracted from resolveIdentifierLocally. (No
    ///     end-to-end MetadataResolver path, but exercises the conversion.)
    ///
    /// Option (b) is the smaller change. Implementation note: extract the
    /// no-author -> .candidate conversion into a static helper on
    /// MetadataResolver (e.g. `static func candidateEnvelope(forNoAuthors:
    /// partialRef:)`) and have both the catch handler in
    /// resolveIdentifierLocally AND this test call it.
    func testNoAuthorsResolverProducesCandidate() async throws {
        let session = StubURLProtocol.makeSession()
        StubURLProtocol.stub(
            "https://ieeexplore.ieee.org/document/8888",
            body: """
            <html><head>
            <meta name="citation_title" content="Author-less IEEE Paper">
            <meta name="citation_doi" content="10.1109/zzz.99999999">
            <meta name="citation_publication_date" content="2024">
            </head></html>
            """
        )
        defer { StubURLProtocol.reset() }

        // Call PaperURLResolver directly to capture the throw payload.
        var caughtPayload: (Reference, String?)?
        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://ieeexplore.ieee.org/document/8888")!,
                session: session
            )
            XCTFail("Expected noAuthorsAvailable")
            return
        } catch PaperURLResolver.ResolveError.noAuthorsAvailable(let ref, let pdf) {
            caughtPayload = (ref, pdf)
        } catch {
            XCTFail("Wrong error: \(error)")
            return
        }

        let (partialRef, _) = caughtPayload!
        XCTAssertEqual(partialRef.title, "Author-less IEEE Paper")
        XCTAssertTrue(partialRef.authors.isEmpty)

        // Verify the conversion produces a .candidate envelope.
        // (If a candidateEnvelope(forNoAuthors:partialRef:) helper exists,
        // call it here. Otherwise, replicate the catch-handler logic from
        // resolveIdentifierLocally inline for this assertion.)
        let candidate = MetadataCandidate(
            source: partialRef.metadataSource ?? .publisherCitationMeta,
            title: partialRef.title,
            authors: partialRef.authors,
            journal: partialRef.journal,
            publisher: partialRef.publisher,
            year: partialRef.year,
            detailURL: partialRef.url ?? "",
            score: 1.0,
            snippet: partialRef.abstract,
            workKind: .unknown,
            referenceType: partialRef.referenceType,
            isbn: partialRef.isbn,
            issn: partialRef.issn,
            sourceRecordID: partialRef.doi
        )
        XCTAssertEqual(candidate.title, "Author-less IEEE Paper")
        XCTAssertEqual(candidate.sourceRecordID, "10.1109/zzz.99999999")
        XCTAssertTrue(candidate.authors.isEmpty)
    }
}
#endif
```

- [ ] **Step 6: Build and test**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build 2>&1 | tail -10
swift test 2>&1 | tail -20
```

Expected: clean build; all non-skipped tests pass.

- [ ] **Step 7: Commit Task 5**

```bash
cd /Users/hzzheng/CodeHub/Rubien
git add Sources/Rubien/Services/MetadataResolver.swift \
        Sources/Rubien/Views/AddByIdentifierView.swift \
        Sources/Rubien/Views/BatchImportView.swift \
        Tests/RubienCoreTests/MetadataResolverPaperURLTests.swift
git commit -m "$(cat <<'EOF'
Rubien: ManualEntryOutcome wrapper for paper-URL PDF override

MetadataResolver.resolveManualEntry now returns ManualEntryOutcome
{ result: MetadataResolutionResult, preferredPDFURL: String? }
instead of bare MetadataResolutionResult. preferredPDFURL is non-nil
only when the resolver's .paperURL path produced a scraped PDF link
and the final result is .verified.

Call sites updated to read .result:
- AddByIdentifierView (also reads .preferredPDFURL)
- BatchImportView (discards URL; batch doesn't auto-download)
- MetadataResolver.retryIntake (returns just .result)

MetadataResolutionResult enum shape is unchanged; the 26 .verified(
pattern-match sites in app/core/tests are untouched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: UI/background PDF override plumbing + AddByIdentifier UI tests

**Files:**
- Modify: `Sources/Rubien/Views/AddByIdentifierView.swift` — onSave signature + toggle gating + placeholder caption.
- Modify: `Sources/Rubien/Views/ContentView.swift` — downloadPDFInBackground signature + onSave consumer update.
- Modify: `Sources/RubienCore/Services/PDFDownloadService.swift` — downloadPDF accepts overrideURL.
- Modify: `Sources/Rubien/Resources/*.xcstrings` (or Localizable.strings) — placeholder caption.
- Create: `Tests/RubienTests/AddByIdentifierPaperURLUITests.swift`

- [ ] **Step 1: Update `PDFDownloadService.downloadPDF` to accept override**

Edit `/Users/hzzheng/CodeHub/Rubien/Sources/RubienCore/Services/PDFDownloadService.swift`. Find `downloadPDF(for:)` (around line 97). Add an `overrideURL` parameter:

```swift
public func downloadPDF(
    for reference: Reference,
    overrideURL: String? = nil
) async throws -> URL {
    if let override = overrideURL?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty,
       let url = URL(string: override) {
        return try await downloadAndStore(url: url, reference: reference)
    }
    // ... existing arXiv / OpenAlex resolution logic unchanged ...
}
```

(If `downloadAndStore` doesn't exist by that exact name, locate the helper that performs the actual download-and-cache and call it with the override URL. Look for `URLSession.shared.download(from:)` or similar in the existing implementation.)

- [ ] **Step 2: Update `AddByIdentifierView.onSave` signature**

Edit `Sources/Rubien/Views/AddByIdentifierView.swift`. Find the property declaration (around line 7):

```swift
let onSave: (Reference, _ downloadPDF: Bool) -> Void
```

Change to:

```swift
let onSave: (Reference, _ downloadPDF: Bool, _ pdfURLOverride: String?) -> Void
```

Update the Import-button action (around line 104-110):

```swift
Button(String(localized: "Import to library", bundle: .module)) {
    if let ref = fetchedReference {
        let canDownload = ref.canDownloadPDF || (preferredPDFURL != nil)
        let shouldDownload = downloadPDFOnImport && canDownload
        onSave(ref, shouldDownload, preferredPDFURL)
        dismiss()
    }
}
```

Update the Toggle gating (around line 74-80):

```swift
Toggle(
    String(localized: "addByIdentifier.downloadPDFOnImport", bundle: .module),
    isOn: $downloadPDFOnImport
)
.toggleStyle(.checkbox)
.disabled(!(ref.canDownloadPDF || preferredPDFURL != nil))
.frame(maxWidth: .infinity, alignment: .leading)
```

Update the placeholder caption (around line 43):

```swift
Text("Supports DOI · arXiv · PMID · PMCID · ISBN · paper URL · title")
```

If the string is sourced from localization (Localizable.xcstrings or similar), update the key value there. Search:

```bash
grep -rn "Supports DOI" Sources/Rubien/Resources/ 2>/dev/null
```

and edit accordingly.

- [ ] **Step 3: Update `ContentView` callers of `AddByIdentifierView`**

Edit `/Users/hzzheng/CodeHub/Rubien/Sources/Rubien/Views/ContentView.swift`. Find where `AddByIdentifierView` is instantiated. The onSave closure needs to accept the third parameter:

```swift
AddByIdentifierView(
    resolver: metadataResolver,
    onSave: { ref, downloadPDF, pdfURLOverride in
        // ... existing save logic ...
        if downloadPDF {
            Task {
                await downloadPDFInBackground(
                    for: savedReference,
                    id: insertedId,
                    pdfURLOverride: pdfURLOverride
                )
            }
        }
    },
    onQueueResult: { ... }
)
```

- [ ] **Step 4: Update `ContentView.downloadPDFInBackground` signature**

Find `downloadPDFInBackground` (around line 350). Add `pdfURLOverride` parameter:

```swift
private func downloadPDFInBackground(
    for reference: Reference,
    id: Int64,
    pdfURLOverride: String? = nil
) async {
    do {
        let downloadedURL = try await pdfDownloadService.downloadPDF(
            for: reference,
            overrideURL: pdfURLOverride
        )
        // ... existing post-download logic unchanged ...
    } catch {
        // ... existing error handling ...
    }
}
```

- [ ] **Step 5: Build and run all tests**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build 2>&1 | tail -10
swift test 2>&1 | tail -20
```

Expected: clean build; all tests pass.

- [ ] **Step 6: Write UI gating tests**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienTests/AddByIdentifierPaperURLUITests.swift`:

*(Note: these tests live in `RubienTests` because they require Mac-only SwiftUI/AppKit. If `AddByIdentifierView`'s gating logic is private, refactor a small testable helper out of it — see step 7.)*

```swift
#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

final class AddByIdentifierGatingTests: XCTestCase {

    /// Mirrors the toggle-gating predicate in AddByIdentifierView. Extracted so
    /// the predicate can be unit-tested without standing up a SwiftUI environment.
    private func toggleDisabled(canDownloadPDF: Bool, preferredPDFURL: String?) -> Bool {
        !(canDownloadPDF || preferredPDFURL != nil)
    }

    /// Mirrors the onSave-time computation for the downloadPDF argument.
    private func shouldDownload(toggleChecked: Bool, canDownloadPDF: Bool, preferredPDFURL: String?) -> Bool {
        toggleChecked && (canDownloadPDF || preferredPDFURL != nil)
    }

    func testToggleDisabledWithNoURLAndNoDOI() {
        XCTAssertTrue(toggleDisabled(canDownloadPDF: false, preferredPDFURL: nil))
    }

    func testToggleEnabledByDOI() {
        XCTAssertFalse(toggleDisabled(canDownloadPDF: true, preferredPDFURL: nil))
    }

    func testToggleEnabledByScrapedURL() {
        XCTAssertFalse(toggleDisabled(canDownloadPDF: false, preferredPDFURL: "https://example.com/foo.pdf"))
    }

    func testToggleEnabledByBoth() {
        XCTAssertFalse(toggleDisabled(canDownloadPDF: true, preferredPDFURL: "https://example.com/foo.pdf"))
    }

    func testOnSaveDownloadWhenToggleCheckedAndURLPresent() {
        XCTAssertTrue(shouldDownload(toggleChecked: true, canDownloadPDF: false, preferredPDFURL: "x"))
    }

    func testOnSaveNoDownloadWhenToggleUnchecked() {
        XCTAssertFalse(shouldDownload(toggleChecked: false, canDownloadPDF: true, preferredPDFURL: "x"))
    }

    func testOnSaveNoDownloadWhenNothingAvailable() {
        XCTAssertFalse(shouldDownload(toggleChecked: true, canDownloadPDF: false, preferredPDFURL: nil))
    }
}
#endif
```

- [ ] **Step 7: Verify the predicates in the test mirror the view code exactly**

Open `AddByIdentifierView.swift` and verify both predicates match. If they drift, either (a) update the test, or (b) refactor: extract `static func toggleDisabled(canDownloadPDF:preferredPDFURL:)` into `AddByIdentifierView` and call it from both the view and the test.

- [ ] **Step 8: Run tests**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test --filter RubienTests.AddByIdentifierGatingTests 2>&1 | tail -15
```

Expected: 7 tests pass.

- [ ] **Step 9: Smoke-test the UI manually (Mac)**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift run Rubien
```

In the running app:
1. Open "Add by Identifier" sheet.
2. Paste `https://openreview.net/forum?id=<a real ID, e.g. one from your own library>`. (If you don't have one, skip to step 4.)
3. Verify the verified card appears, "Also download PDF" toggle is enabled, and clicking Import attaches a PDF.
4. Paste a bare DOI you've used before — verify behavior unchanged.
5. Paste a malformed URL or random text — verify rejected message appears.

Close the app. If any step misbehaves, debug before committing.

- [ ] **Step 10: Commit Task 6**

```bash
cd /Users/hzzheng/CodeHub/Rubien
git add Sources/Rubien/Views/AddByIdentifierView.swift \
        Sources/Rubien/Views/ContentView.swift \
        Sources/RubienCore/Services/PDFDownloadService.swift \
        Sources/Rubien/Resources/ \
        Tests/RubienTests/AddByIdentifierPaperURLUITests.swift
git commit -m "$(cat <<'EOF'
Rubien UI: thread pdfURLOverride through Add-by-Identifier import

- AddByIdentifierView.onSave gains a third pdfURLOverride: String?
  parameter, passed to ContentView's downloadPDFInBackground.
- Toggle is now enabled when canDownloadPDF OR a scraped PDF URL is
  available (covers OpenReview/CVF/PMLR papers with no DOI).
- ContentView.downloadPDFInBackground gains pdfURLOverride parameter
  forwarded to PDFDownloadService.downloadPDF(for:overrideURL:).
- PDFDownloadService.downloadPDF takes overrideURL? — when non-nil,
  skips arXiv/OpenAlex resolution and downloads the URL directly.
- Placeholder caption updated to include "paper URL".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Canonical-URL dedup test + gated live smoke tests + fixture refresh script

**Files:**
- Create: `Tests/RubienCoreTests/ReferenceDuplicateCanonicalURLTests.swift`
- Create: `Tests/RubienCoreTests/PaperURLLiveSmokeTests.swift`
- Create: `Scripts/refresh-citation-fixtures.sh`

- [ ] **Step 1: Write the canonical-URL dedup regression test**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/ReferenceDuplicateCanonicalURLTests.swift`:

```swift
import XCTest
import GRDB
@testable import RubienCore

final class ReferenceDuplicateCanonicalURLTests: XCTestCase {

    // Setup pattern verified by `grep -n "AppDatabase(DatabaseQueue" Tests/RubienCoreTests/`:
    // existing tests like `StatusOptionMutationTests` and `MigrationV4Tests` use
    // `try AppDatabase(DatabaseQueue())` for in-memory databases.

    func testCanonicalFormDeduplicatesEquivalentURLs() throws {
        let appDB = try AppDatabase(DatabaseQueue())

        // Insert a paper-URL-derived reference with a canonical URL via the
        // same insert pattern existing tests use. (Look at how
        // StatusOptionMutationTests / MigrationV4Tests insert records — most
        // use `try appDB.dbWriter.write { db in try ref.insert(db) }`.)
        //
        // AuthorName.init signature is `(given: String, family: String)` —
        // verified at Sources/RubienCore/Models/Reference.swift:33. The plan
        // previously had the labels reversed.
        var first = Reference(
            title: "Sample Paper",
            authors: [AuthorName(given: "J.", family: "Smith")],
            referenceType: .conferencePaper,
            url: "https://openreview.net/forum?id=ABCD",
            metadataSource: .publisherCitationMeta
        )
        let firstID = try appDB.dbWriter.write { db -> Int64 in
            try first.insert(db)
            return first.id ?? db.lastInsertedRowID
        }

        // Simulate a second paste with a non-canonical form. After Task 3's
        // canonicalization, both should produce the same canonical URL.
        let inputURL = URL(string: "HTTPS://WWW.OPENREVIEW.NET/forum?id=ABCD#fragment")!
        let canonical = PaperURLResolver.canonicalize(inputURL)?.absoluteString
        XCTAssertEqual(canonical, "https://openreview.net/forum?id=ABCD")

        let probe = Reference(
            title: "Sample Paper (re-paste)",
            authors: [AuthorName(given: "J.", family: "Smith")],
            referenceType: .conferencePaper,
            url: canonical,
            metadataSource: .publisherCitationMeta
        )

        // findDuplicateReferenceID is an instance method on AppDatabase
        // (Sources/RubienCore/Database/AppDatabase.swift:1958), NOT a static.
        // Call through dbWriter.read.
        let match = try appDB.dbWriter.read { db in
            try appDB.findDuplicateReferenceID(for: probe, db: db)
        }
        XCTAssertEqual(match?.id, firstID,
                       "Canonical URL should match the existing row's URL")
    }
}
```

**Important — verify these assumptions before running:**
- `Reference.insert(_ db:)` (GRDB persistence) actually exists. If references go through `AppDatabase.insertReference(_:)` or a similar wrapper, use that instead.
- `findDuplicateReferenceID(for:db:)` is `internal` and callable from `@testable import RubienCore` — if not, expose it as `internal` or move the test to the `RubienCore` target itself.
- `appDB.dbWriter` is the GRDB writer handle. If `AppDatabase` exposes a different property name (`writer`, `database`, etc.), substitute accordingly. Cross-reference with how `StatusOptionMutationTests.swift` writes test data.

- [ ] **Step 2: Write the gated live smoke tests**

Create `/Users/hzzheng/CodeHub/Rubien/Tests/RubienCoreTests/PaperURLLiveSmokeTests.swift`:

```swift
import XCTest
@testable import RubienCore

/// Live smoke tests against real publisher URLs. Skipped in CI by default.
/// Run with `RUBIEN_LIVE_TESTS=1 swift test --filter PaperURLLiveSmokeTests`.
final class PaperURLLiveSmokeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? XCTSkipIf(ProcessInfo.processInfo.environment["RUBIEN_LIVE_TESTS"] != "1",
                       "Set RUBIEN_LIVE_TESTS=1 to run live smoke tests")
    }

    private func smokeURL(_ s: String, expectedTitleContains: String, file: StaticString = #file, line: UInt = #line) async throws {
        let url = URL(string: s)!
        let outcome = try await PaperURLResolver.resolve(url)
        XCTAssertFalse(outcome.reference.title.isEmpty, file: file, line: line)
        XCTAssertTrue(outcome.reference.title.lowercased().contains(expectedTitleContains.lowercased()),
                      "Expected title to contain '\(expectedTitleContains)', got '\(outcome.reference.title)'",
                      file: file, line: line)
        XCTAssertFalse(outcome.reference.authors.isEmpty, file: file, line: line)
    }

    // EDITOR: Update these URLs (and expected titles) with real, stable
    // landing pages before shipping. Synthetic placeholders here.

    func testOpenReviewLive() async throws {
        try await smokeURL(
            "https://openreview.net/forum?id=YicbFdNTTy",  // a real "Attention is all you need"-style ID
            expectedTitleContains: "attention"
        )
    }

    func testACLAnthologyLive() async throws {
        try await smokeURL(
            "https://aclanthology.org/2023.acl-long.1/",  // pick a real stable URL
            expectedTitleContains: ""  // skip text assertion if URL is unstable
        )
    }

    // Add similar smokeURL calls for the remaining 8 hosts when stable URLs
    // are identified. See Scripts/refresh-citation-fixtures.sh for the
    // capture-and-update workflow.
}
```

- [ ] **Step 3: Write the fixture refresh script**

Create `/Users/hzzheng/CodeHub/Rubien/Scripts/refresh-citation-fixtures.sh`:

```bash
#!/usr/bin/env bash
# Re-capture HTML for citation-meta test fixtures.
#
# Usage: ./Scripts/refresh-citation-fixtures.sh <fixture-name> <source-url>
#
# Example:
#   ./Scripts/refresh-citation-fixtures.sh openreview-forum \
#     https://openreview.net/forum?id=ABCD
#
# Output:
#   - Saves the full page <head> to Tests/RubienCoreTests/Fixtures/CitationMeta/<fixture-name>.html
#   - Updates the comment header with source URL and capture date
#   - Prints a diff against the previous version

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <fixture-name> <source-url>" >&2
    exit 1
fi

FIXTURE_NAME="$1"
SOURCE_URL="$2"
FIXTURE_DIR="$(cd "$(dirname "$0")"/.. && pwd)/Tests/RubienCoreTests/Fixtures/CitationMeta"
FIXTURE_PATH="$FIXTURE_DIR/${FIXTURE_NAME}.html"
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

CAPTURE_DATE="$(date -u +%Y-%m-%d)"
USER_AGENT="Rubien/1.0 (fixture-refresh; mailto:devzhk@gmail.com)"

echo "Fetching $SOURCE_URL ..."
curl -sSL -A "$USER_AGENT" -o "$TMPFILE" "$SOURCE_URL"

# Prepend a comment header
{
    echo "<!--"
    echo "SOURCE: $SOURCE_URL"
    echo "CAPTURED: $CAPTURE_DATE"
    echo "-->"
    cat "$TMPFILE"
} > "$FIXTURE_PATH.new"

if [[ -f "$FIXTURE_PATH" ]]; then
    echo "Diff against existing fixture:"
    diff -u "$FIXTURE_PATH" "$FIXTURE_PATH.new" || true
fi

mv "$FIXTURE_PATH.new" "$FIXTURE_PATH"
echo "Updated $FIXTURE_PATH"
echo
echo "Next steps:"
echo "  1. Inspect $FIXTURE_PATH manually."
echo "  2. Run: swift test --filter CitationMetaScraperParseTests"
echo "  3. If assertions need updating, edit Tests/RubienCoreTests/CitationMetaScraperParseTests.swift"
```

Make it executable:

```bash
chmod +x /Users/hzzheng/CodeHub/Rubien/Scripts/refresh-citation-fixtures.sh
```

- [ ] **Step 4: Run all tests one final time**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build 2>&1 | tail -10
swift test 2>&1 | tail -30
```

Expected: clean build, all non-skipped tests pass.

- [ ] **Step 5: Commit Task 7**

```bash
cd /Users/hzzheng/CodeHub/Rubien
git add Tests/RubienCoreTests/ReferenceDuplicateCanonicalURLTests.swift \
        Tests/RubienCoreTests/PaperURLLiveSmokeTests.swift \
        Scripts/refresh-citation-fixtures.sh
git commit -m "$(cat <<'EOF'
RubienCore tests: canonical-URL dedup + gated live smoke + refresh

- ReferenceDuplicateCanonicalURLTests verifies the canonical URL form
  chosen in PaperURLResolver.canonicalize actually deduplicates against
  findDuplicateReferenceID's exact-string URL match.
- PaperURLLiveSmokeTests.swift runs against real publisher URLs when
  RUBIEN_LIVE_TESTS=1 is set; skipped in CI by default.
- Scripts/refresh-citation-fixtures.sh re-captures <head> from a
  source URL into the fixtures directory with a diff against previous
  state. Use when a smoke test starts failing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Post-implementation verification

After all 7 tasks land:

- [ ] **Run the full test suite**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift test 2>&1 | tail -40
```

Expected: all tests pass.

- [ ] **Smoke-test in the Mac app**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift run Rubien
```

Verify:
1. **OpenReview URL paste** → produces a verified `.conferencePaper`, "Also download PDF" toggle enabled.
2. **ACL Anthology PDF URL paste** → rewrites to landing → verified with CrossRef DOI merge.
3. **Springer search URL paste** (`https://link.springer.com/search?q=neural`) → falls through to title-search (or rejects); does NOT match paper URL path.
4. **Bare DOI paste** → unchanged behavior.
5. **CVF Open Access landing URL paste** → produces verified `.conferencePaper` via BibTeX.

- [ ] **Run the CLI smoke test**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift run rubien-cli add --identifier "https://openreview.net/forum?id=<real-id>"
```

Expected: produces JSON output with a verified Reference.

- [ ] **Optional: run live smoke tests once before merging**

```bash
RUBIEN_LIVE_TESTS=1 swift test --filter PaperURLLiveSmokeTests 2>&1 | tail -20
```

Expected: at least the two enabled smoke tests pass against real publisher URLs.

If everything passes, the feature is ready to ship. The 4 commits from Tasks 1, 2, 3, 4, 5, 6, 7 should be reviewed and merged together.

---

## Out-of-scope follow-ups documented in the spec

These do NOT need to be addressed in this implementation but should be filed as separate issues:

1. **`BibTeXImporter.swift:113` arXiv-as-webpage bug** — `@misc{}` entries from arXiv import as `.webpage` instead of `.journalArticle`/`.preprint`.
2. **Bulk BibTeX import lacks PDF-download affordance.**
3. **Backfill `MetadataSource.crossref` case** — current CrossRef-fetched references are labeled `.translationServer`.
4. **Springer PDF→landing rewrite via DOI content-type resolution** — `/content/pdf/<doi>` can't be blindly rewritten without knowing if the DOI resolves to article/chapter/book.
5. **In-flight coalescing for duplicate concurrent paste** — `NSCache` doesn't deduplicate in-flight requests.
6. **Shared HTTP client extraction (`RubienHTTPClient`)** — if a fourth HTTP caller appears, extract a shared client.
7. **Canonical-URL duplicate detection misses legacy non-canonical rows** — pre-existing URL-only references won't match newly canonicalized URLs.
