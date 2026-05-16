# Paper landing-page URL resolver

**Status:** drafted 2026-05-16 — awaiting user review
**Scope:** Extend `MetadataResolver.resolveManualEntry` to recognize paper landing-page URLs (OpenReview, ACL Anthology, CVF Open Access, NeurIPS, PMLR, IEEE Xplore, ACM DL, Nature, Springer, …) and resolve them to authoritative `Reference` records, with optional PDF auto-download. Two new files in `RubienCore/Services/`, one extension to `MetadataFetcher.Identifier`, no model changes, no sync surface change.
**Out of scope:** Web Import flow (`ClipperWebMetadataExtractor` / `WebImportView`), bulk URL import, browser extension / share sheet, JavaScript-rendered pages requiring WebKit, generic non-paper webpage scraping, the two pre-existing BibTeX-importer bugs called out at the bottom of this spec.

## Problem

Today the Add-by-Identifier paste box (`AddByIdentifierView` → `MetadataResolver.resolveManualEntry` → `MetadataFetcher.extractIdentifier`) recognizes only DOI, arXiv ID, PMID, PMCID, ISBN, or a paper title. When a user pastes one of these URLs:

- `https://openreview.net/forum?id=ABCD` (no DOI)
- `https://aclanthology.org/2024.acl-long.123/` (DOI in page, not in URL)
- `https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html` (no DOI anywhere)
- `https://proceedings.neurips.cc/paper_files/paper/2024/hash/abc.html` (no DOI)
- `https://proceedings.mlr.press/v200/foo23a.html` (no DOI)

…the input is not recognized as a paper. `extractIdentifier` returns `nil` and the pipeline falls through to a title-search-on-URL-string, which never matches. The user either gives up, or copies the title manually and re-pastes.

The Web Import flow (`ClipperWebMetadataExtractor`) is the wrong tool for this: it runs Defuddle/Readability on the page in a hidden `WKWebView`, produces a `referenceType: .webpage` Reference (intended for blog posts and news articles), and is Mac-only by linkage to `WebKit`.

## Goals

- Pasting a paper landing-page URL into Add-by-Identifier produces an authoritative `Reference` (article / inproceedings type) on the same path as a pasted DOI.
- Direct-PDF URLs from the same sites work too (rewritten to landing-page URL, then scraped).
- The feature works in both the Mac app and `rubien-cli` — implementation lives in `RubienCore`, no `WebKit` dependency, pure `URLSession` + HTML parsing.
- New sites with `<meta name="citation_*">` tags need zero code to add (only an entry in the host allowlist).
- No new persistent `Reference` fields; no `CKRecord` field changes; no migrations.

## Non-goals

- Reworking the Web Import flow for non-paper URLs.
- Building a generic "any URL → reference" extractor. URLs outside the allowlist still fall through to today's title-search path.
- Fixing the two pre-existing BibTeX importer bugs (`@misc` → `.webpage`, no PDF-download offer in bulk BibTeX import). Flagged below as separate follow-ups.
- JavaScript-rendered pages. All target sites render `<meta>` tags server-side; we never need a headless browser.
- Caching scraped HTML beyond the existing 5-minute `responseCache` in `MetadataFetcher`.

## Design

### 1. Architecture

Two new files in `Sources/RubienCore/Services/`, plus one case added to an existing enum:

```
RubienCore/Services/
├── PaperURLResolver.swift       (NEW — orchestrator: host classify, PDF→landing rewrite, dispatch)
├── CitationMetaScraper.swift    (NEW — generic <meta name="citation_*"> HTML parser)
└── MetadataFetcher.swift        (EDIT — add Identifier.paperURL(URL) case)
```

Flow when user pastes `https://openreview.net/forum?id=ABCD`:

```
AddByIdentifierView
  └─> MetadataResolver.resolveManualEntry(text)
        └─> MetadataFetcher.extractIdentifier(text)
              returns .paperURL(URL)
        └─> MetadataResolver.resolveIdentifierLocally(.paperURL(url), ...)
              └─> PaperURLResolver.resolve(url)
                    ├─ rewritePDFURLToLanding(url)              // per-host
                    ├─ host == thecvf:  CVF BibTeX adapter (uses BibTeXImporter)
                    │  else:            CitationMetaScraper.fetch
                    ├─ if citation_doi present:
                    │       MetadataFetcher.fetchFromDOI(doi)   // canonical
                    │       merge scraper abstract if CrossRef lacks one
                    │       keep scrapedPDFURL for download step
                    └─ return Outcome(reference, scrapedPDFURL)
        └─> verifyFetchedRecord — produces VerifiedEnvelope (treated like a direct
            identifier lookup; manual-confirmation evidence)
  └─> AddByIdentifierView renders verified card with the existing "Also download PDF"
      Toggle, then on Import calls onSave(reference, downloadPDF, pdfURLOverride)
  └─> PDFDownloadService — uses pdfURLOverride if non-nil; else existing
      arXiv/OpenAlex resolution path.
```

The scraped PDF URL is **threaded through the resolution envelope and the import callback** — not stored on `Reference`. Once import finishes, the URL is no longer needed (the file is in the local PDF cache; the landing-page URL on `Reference.url` is enough for "open original" affordances).

`MetadataFetcher.Identifier` gains one case:

```swift
public enum Identifier: Equatable {
    case doi(String)
    case pmid(String)
    case arxiv(String)
    case isbn(String)
    case pmcid(String)
    case paperURL(URL)   // NEW
}
```

`MetadataResolver.resolveIdentifierLocally` gains a `.paperURL` branch that delegates to `PaperURLResolver.resolve`.

### 2. Components

#### `CitationMetaScraper`

One job: fetch a URL, parse `<meta name="citation_*">` tags, return a structured result.

```swift
public struct CitationMetaResult {
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
}

public enum CitationMetaScraper {
    public static func fetch(_ url: URL) async throws -> CitationMetaResult
}
```

Implementation notes:

- Uses the same `URLSession`, `userAgent`, and `withRetry` machinery as `MetadataFetcher`. 15-second timeout to match existing CrossRef/arXiv calls.
- HTML parsing is regex/scanner over the `<head>` portion of the response, not a full DOM parser. `<meta>` tags in `<head>` are flat, well-formed across all target sites, and don't require nested-tag handling. If a `<title>` tag is found and `citation_title` is absent, fall back to it (some sites only expose `<title>`).
- `citation_author` appears once per author — we collect all occurrences in document order. `AuthorName.parseList` handles the "Lastname, Firstname" format these sites emit.
- `citation_publication_date` formats vary: `2024/06/12`, `2024-06-12`, `2024`. We accept any of these and extract the year. If only `citation_year` is present, prefer that.
- `citation_abstract` is rare; `og:description` is more common but often a truncated paragraph. We accept either, preferring `citation_abstract` when both present.
- The scraper does **not** infer `referenceType` — that's the orchestrator's job, since the orchestrator knows the host.

#### `PaperURLResolver`

Orchestrator with three responsibilities:

**A. Host classification** — does this URL belong to a known paper site?

```swift
internal enum KnownPaperHost: CaseIterable {
    case openReview          // openreview.net
    case aclAnthology        // aclanthology.org
    case cvfOpenAccess       // openaccess.thecvf.com
    case neurIPS             // papers.nips.cc, proceedings.neurips.cc
    case pmlr                // proceedings.mlr.press
    case ieeeXplore          // ieeexplore.ieee.org
    case acmDL               // dl.acm.org
    case nature              // nature.com, www.nature.com
    case springer            // link.springer.com
    case scienceDirect       // www.sciencedirect.com

    static func classify(_ url: URL) -> KnownPaperHost?
}
```

The same classifier is called from `MetadataFetcher.extractIdentifier` (to recognize the URL as `.paperURL`) and from `PaperURLResolver.resolve` (to dispatch). One source of truth, one allowlist to extend.

**B. PDF-URL → landing-page rewrite** — per-host rules. Examples:

| Input PDF URL | Rewritten landing URL |
|---|---|
| `openreview.net/pdf?id=ABCD` | `openreview.net/forum?id=ABCD` |
| `aclanthology.org/2024.acl-long.123.pdf` | `aclanthology.org/2024.acl-long.123/` |
| `openaccess.thecvf.com/.../papers/Foo.pdf` | `openaccess.thecvf.com/.../html/Foo.html` |
| `proceedings.mlr.press/v200/foo23a/foo23a.pdf` | `proceedings.mlr.press/v200/foo23a.html` |
| `proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Conference.pdf` | `proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Conference.html` |

For each host, the rewrite is a single regex/string substitution. If the input URL is already a landing URL (no rewrite needed), the function returns it unchanged.

If a rewrite produces a URL we then fail to fetch, we don't silently fall back to fetching the PDF directly — we surface the rewrite failure (see error handling below). PDF-text extraction is a separate import flow and not invoked here.

**C. Dispatch and post-processing**

```swift
public enum PaperURLResolver {
    public struct Outcome {
        public let reference: Reference
        public let scrapedPDFURL: String?
    }
    public static func resolve(_ url: URL) async throws -> Outcome
}
```

Algorithm:

1. Classify host. If `nil`, throw — caller treats this as "URL not recognized" (callable only from the `.paperURL` branch, so in practice this is a defensive check).
2. Rewrite PDF URL to landing URL if applicable.
3. If host == `.cvfOpenAccess`, run the CVF BibTeX adapter (see §3 Data flow, Case C). Otherwise, run `CitationMetaScraper.fetch`.
4. Build a draft `Reference` from the scraper result. `referenceType` chosen from the host bucket:
   - `.cvfOpenAccess`, `.neurIPS`, `.pmlr` → `.conferencePaper`
   - `.aclAnthology` → `.conferencePaper` if `citation_conference_title` present, else `.journalArticle`
   - `.openReview` → `.conferencePaper` (OpenReview hosts venue submissions; journals are rare and still acceptable here)
   - `.ieeeXplore`, `.acmDL`, `.nature`, `.springer`, `.scienceDirect` → `.journalArticle` if `citation_journal_title` present, else `.conferencePaper` if `citation_conference_title`, else `.journalArticle` as default
5. If `result.doi` is non-nil, call `MetadataFetcher.fetchFromDOI(doi)`. On success, the CrossRef Reference replaces the draft; the **only** scraper field merged in is `abstract` when CrossRef returned none (`reference.abstract ??= scraper.abstract`). `pdfURL` is not a `Reference` field — it travels on `Outcome.scrapedPDFURL` and is preserved across this branch. On failure, log via `resolverTrace` and keep the scraper-only Reference (graceful degradation — see Error handling §4).
6. `Reference.url` is set to the **landing-page URL** (post-rewrite, pre-CrossRef-substitution), so "open original" affordances point to the publisher page the user expects, not a `doi.org` redirect.
7. `Reference.metadataSource` is set to one of:
   - `.crossref` (existing) — when the DOI re-fetch in step 5 succeeded.
   - `.cvfOpenAccess` (NEW) — when the CVF BibTeX adapter produced the Reference.
   - `.publisherCitationMeta` (NEW) — for every other case (citation_* scraper produced the Reference, no DOI re-fetch or DOI re-fetch failed).
   Two new `MetadataSource` cases total. Existing cases are not renamed or removed (forward-compatible decode requirement from `CLAUDE.md`).
8. Return `Outcome(reference, scrapedPDFURL: result.pdfURL)`.

#### `MetadataFetcher.extractIdentifier` — extended

Adds a single URL-host check at the top of the function, before the existing PMCID/DOI/arXiv checks:

```swift
public static func extractIdentifier(from text: String) -> Identifier? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // NEW: paper landing-page URL on a known host
    if let url = URL(string: trimmed),
       let scheme = url.scheme?.lowercased(),
       (scheme == "http" || scheme == "https"),
       KnownPaperHost.classify(url) != nil {
        return .paperURL(url)
    }

    // ... existing PMCID/DOI/arXiv/ISBN/PMID checks unchanged ...
}
```

Ordering matters: the paper-URL check goes **before** the DOI check. This way a Nature URL like `https://www.nature.com/articles/s41586-024-12345-6` (which contains a DOI-shaped path segment) routes through `PaperURLResolver` once, which then re-fetches the canonical DOI via CrossRef. Without this ordering, the DOI regex would match `nature.com/articles/s41586-024-12345-6` directly and skip the landing-page scrape, losing per-host context like the correct `Reference.url`.

#### `MetadataResolver.resolveIdentifierLocally` — extended

```swift
case .paperURL(let url):
    let outcome = try await PaperURLResolver.resolve(url)
    reference = outcome.reference
    // scrapedPDFURL surfaced via a new field on AuthoritativeMetadataRecord (see §3)
```

The `scrapedPDFURL` is threaded through `AuthoritativeMetadataRecord` → `VerifiedEnvelope` → out to `AddByIdentifierView`, then to the existing `onSave` callback, extended from `(Reference, downloadPDF: Bool)` to `(Reference, downloadPDF: Bool, pdfURLOverride: String?)`. `PDFDownloadService` accepts the override and skips its arXiv/OpenAlex lookup when one is provided.

### 3. Data flow — three representative cases

**Case A — OpenReview landing page** (no DOI):

```
input: https://openreview.net/forum?id=ABCD
 1. extractIdentifier  -> .paperURL(URL)
 2. PaperURLResolver.resolve
      host = .openReview
      rewritePDFURLToLanding: no-op (already landing page)
      CitationMetaScraper.fetch -> CitationMetaResult
        { title: "...", authors: [...], year: 2024,
          conferenceTitle: "ICLR 2024", abstract: "...",
          pdfURL: "https://openreview.net/pdf?id=ABCD" }
      doi == nil -> build Reference directly
        referenceType = .conferencePaper
        metadataSource = .openReview
        url = "https://openreview.net/forum?id=ABCD"
 3. Outcome(reference, scrapedPDFURL: "https://openreview.net/pdf?id=ABCD")
 4. MetadataResolver wraps in VerifiedEnvelope
 5. AddByIdentifierView renders verified card, toggle enabled, user clicks Import
 6. onSave(reference, downloadPDF: true, pdfURLOverride: "https://openreview.net/pdf?id=ABCD")
 7. PDFDownloadService downloads from override URL, hashes, stores via PDFAssetCache
```

**Case B — ACL Anthology direct-PDF URL** (DOI present):

```
input: https://aclanthology.org/2024.acl-long.123.pdf
 1. extractIdentifier  -> .paperURL(URL)
 2. PaperURLResolver.resolve
      host = .aclAnthology
      rewritePDFURLToLanding: -> https://aclanthology.org/2024.acl-long.123/
      CitationMetaScraper.fetch (on landing URL)
        { ..., doi: "10.18653/v1/2024.acl-long.123", pdfURL: ".../123.pdf" }
      doi present -> MetadataFetcher.fetchFromDOI("10.18653/v1/2024.acl-long.123")
        -> Reference from CrossRef (canonical authors, pages, abstract, …)
        merge: reference.abstract ??= scraper.abstract  (CrossRef sometimes lacks)
        reference.url = "https://aclanthology.org/2024.acl-long.123/"  (landing, not doi.org)
        metadataSource = .crossref
        scrapedPDFURL kept for download step
 3..7 same as Case A
```

**Case C — CVF Open Access** (no `citation_*` meta):

```
input: https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html
 1. extractIdentifier  -> .paperURL(URL)
 2. PaperURLResolver.resolve
      host = .cvfOpenAccess
      CVF BibTeX adapter (inline in PaperURLResolver.swift):
        - GET landing page
        - Extract <pre> BibTeX block via regex on the response body
          (CVF pages have exactly one <pre>...</pre> containing the BibTeX)
        - Parse with BibTeXImporter.parse — returns [Reference]; take first.
          If parse returns empty array or first.title is blank, treat as
          extraction failure (see Error handling §4 row "BibTeX block found
          but Reference has empty title").
        - Synthesize pdfURL by string substitution:
            ".../html/Foo_paper.html" -> ".../papers/Foo_paper.pdf"
      Reference{ referenceType: .conferencePaper,
                 journal: "Proceedings of the IEEE/CVF Conference on...",
                 eventTitle: same (set by BibTeXImporter when entryType=inproceedings),
                 ... }
      url = "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html"
      metadataSource = .cvfOpenAccess
 3..7 same as Case A
```

### 4. Error handling

Same `MetadataResolutionResult` machinery the existing identifier path uses; no new envelope types.

| Condition | Result | User-facing message |
|---|---|---|
| URL host not in allowlist | falls through `extractIdentifier`; existing title-search path applies | (unchanged) |
| Allowlisted host, GET returns 4xx/5xx | `.rejected(insufficientEvidence)` | "Could not load <host> page (HTTP <code>). Check the URL or try a DOI." |
| Allowlisted host, GET succeeds but scraper extracts < 2 useful fields (title + at least one of authors / year / journal / conferenceTitle) | `.rejected(insufficientEvidence)` | "Page did not expose paper metadata. Try pasting the DOI or paper title." |
| Scraper produces DOI, CrossRef call fails (network / 5xx / parse) | **fall through** — return scraper-only Reference; log via `resolverTrace`. **Not** an error. | (no error surfaced; user sees verified card with scraper fields) |
| Network timeout (15s, matches `MetadataFetcher` existing timeout) | `.rejected(insufficientEvidence)` | `error.localizedDescription` |
| CVF page returns 200 but no `<pre>` BibTeX block matches | `.rejected(insufficientEvidence)` | "Could not find BibTeX on this CVF page. The page format may have changed." |
| PDF-URL rewrite produces a URL we then fail to fetch | `.rejected(insufficientEvidence)` | "Loaded PDF URL but no matching landing page. Try the abstract page URL." |
| BibTeXImporter returns a Reference but with empty title | `.rejected(insufficientEvidence)` | "Found BibTeX but it did not contain usable fields." |

**Two policy choices encoded above:**

- **CrossRef-fail is non-fatal.** A scraped Reference with DOI degrades to scraper-only when CrossRef hiccups. CrossRef outages happen; users keep moving.
- **No fallback to title-search.** When a paper URL fails extraction, we don't silently re-query OpenAlex by the page `<title>`. Silent re-routing of pasted URLs is confusing UX. User gets a clear rejection and can paste a DOI/title themselves.

### 5. Testing

All new tests live in `RubienCoreTests` (fastest target; no SwiftUI dep). No new test target.

**New test files**

1. **`CitationMetaScraperTests.swift`** — fixture-driven HTML parsing
   - One fixture file per real site in `Tests/RubienCoreTests/Fixtures/CitationMeta/`, captured once from a real page, header-commented with source URL and date:
     - `openreview-forum.html` (no DOI)
     - `aclanthology-paper.html` (with `citation_doi`)
     - `neurips-proceedings.html`
     - `pmlr-paper.html`
     - `ieee-xplore.html`
     - `nature-article.html`
     - `springer-chapter.html`
     - `acm-dl.html`
   - Each test: feed fixture HTML directly to the parser (no network), assert on every populated `CitationMetaResult` field.
   - Negative fixtures:
     - `partial-meta-only-title.html` — should produce result with title only.
     - `no-citation-meta.html` — empty result.
     - `malformed-meta.html` (unclosed tags, weird encoding) — does not crash; partial result acceptable.

2. **`PaperURLResolverTests.swift`** — orchestrator behavior
   - Host classification table test: array of (URL, expected `KnownPaperHost?`) pairs covering all 10 hosts plus negatives.
   - PDF → landing rewrite table test, per-host, including edge cases (URL with query string, fragment, trailing slash variants).
   - DOI re-fetch behavior, with stubbed `MetadataFetcher`:
     - scraper finds DOI → CrossRef succeeds → Outcome reference is CrossRef-canonical; scraper abstract merged in if CrossRef lacks one.
     - scraper finds DOI → CrossRef fails → Outcome reference is scraper-only; no error thrown.
   - Field merge precedence (CrossRef wins on shared fields; scraper fills holes).
   - CVF dispatch: `thecvf` URL routes through `BibTeXImporter`, not `CitationMetaScraper`.
   - `Reference.url` is the landing-page URL after rewrite, regardless of whether CrossRef substituted other fields.

3. **`BibTeXImporterCVFTests.swift`** *(closes the gap that `BibTeXImporter.parse(_:)` has no direct unit tests today)*
   - 6–10 real CVF BibTeX blocks pulled from current CVPR/ICCV/WACV/ECCV pages, asserted field-by-field.
   - Specific cases included:
     - Standard CVPR `@InProceedings` (5+ authors).
     - Title with LaTeX brace protection (`{S}^n`-style).
     - Block with `month = june` (bare word, not number) — exercises `parseMonth` bare-word branch.
     - Block followed by HTML noise (mimics the `<pre>` extraction surrounding the BibTeX in a CVF landing page).
     - Block with no `doi` field (CVF typically omits DOIs).
     - Block with multi-line title (line-wrapped at column 80, a real Bib format quirk).

**Extended existing tests**

4. **New extraction cases on `MetadataFetcher`** (in a new file `PaperURLExtractionTests.swift` rather than appending to existing identifier tests, to keep the file focused):
   - `https://openreview.net/forum?id=ABCD` → `.paperURL`
   - `https://openreview.net/pdf?id=ABCD` → `.paperURL`
   - `https://aclanthology.org/2024.acl-long.123/` → `.paperURL`
   - `https://www.nature.com/articles/s41586-024-12345-6` → `.paperURL` (verifying paper-URL check beats DOI extraction for known hosts — see §2 ordering note).
   - `https://example-blog.com/post/hello` → `nil` (falls through to title-search).
   - `10.1234/abc` (bare DOI, not a URL) → existing `.doi(...)` behavior unchanged — regression coverage.

5. **`MetadataResolverPaperURLTests.swift`** — integration-level, stubbed network
   - One test per representative adapter family:
     - citation_* only (OpenReview-style) → verified Reference matches expected fields.
     - citation_* + DOI (ACL-style) → CrossRef called, merged Reference.
     - CVF BibTeX → BibTeXImporter called, Reference fields match.
   - One failure-path test per error class from §4.

**Tests we are NOT writing (and why)**

- **CLI integration tests** — `rubien-cli add` already exercises `resolveManualEntry`. If the unit tests pass, the CLI works. Existing `RubienCLITests` JSON-contract tests already cover the surface; no new subcommand → no new JSON contract.
- **SwiftUI snapshot tests** on `AddByIdentifierView` — the view layer change is "placeholder string + one extra optional argument threaded through one callback." Nothing visual-regression-worthy.
- **`RubienSyncTests`** — no model field changes, no `CKRecord` changes.

**Live-fixture rot mitigation**

Real-world HTML fixtures rot — sites redesign their meta tags every couple of years. Two cheap mitigations:

- Each fixture file has a comment header noting the source URL and the date captured.
- A `Tests/RubienCoreTests/Fixtures/CitationMeta/FIXTURE-NOTES.md` lists every site we depend on and the canonical meta-tag set we expect, so when a test breaks, the maintainer can re-capture from a current page and diff.

## Implementation order

1. `CitationMetaScraper.swift` + `CitationMetaScraperTests.swift` with fixtures. Pure logic, no other dependencies — land first.
2. `BibTeXImporterCVFTests.swift`. Adds direct unit tests on the existing importer with CVF fixtures. Land second so the BibTeX path is locked in before we depend on it.
3. `PaperURLResolver.swift` (host classifier + PDF→landing rewrite + dispatch) + `PaperURLResolverTests.swift`. Uses (1) and (2).
4. Extend `MetadataFetcher.Identifier` and `extractIdentifier` + `PaperURLExtractionTests.swift`.
5. Extend `MetadataResolver.resolveIdentifierLocally` and the envelope plumbing for `scrapedPDFURL` + `MetadataResolverPaperURLTests.swift`.
6. UI thread-through in `AddByIdentifierView` (callback signature change), `PDFDownloadService` (accept URL override), and the placeholder caption ("Supports DOI · arXiv · PMID · PMCID · ISBN · paper URL · title").

Each step is a single commit that builds, passes its own tests, and is reviewable independently.

## Out-of-scope follow-ups (file separately)

Surfaced during this design but explicitly **not** addressed here:

- **`BibTeXImporter.swift:113`** — arXiv `@misc{}` entries import as `.webpage`. Should detect `archivePrefix = {arXiv}` / `eprint = {…}` / arxiv.org URL and return `.journalArticle` (or `.preprint` if added). Pre-existing bug; user-reported during this design's review.
- **Bulk BibTeX import has no "Also download PDF" affordance.** Bulk-import via `ContentView.swift:618` doesn't route through `AddByIdentifierView` and never offers the toggle. Pre-existing UX gap; user-reported during this design's review.
