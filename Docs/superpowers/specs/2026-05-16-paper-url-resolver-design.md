# Paper landing-page URL resolver

**Status:** revised 2026-05-16 after Codex first-pass review — awaiting second-pass Codex review
**Scope:** Extend `MetadataResolver.resolveManualEntry` to recognize paper landing-page URLs (OpenReview, ACL Anthology, CVF Open Access, NeurIPS, PMLR, IEEE Xplore, ACM DL, Nature, Springer, ScienceDirect) and resolve them to authoritative `Reference` records, with optional PDF auto-download. Three new files in `RubienCore/`, one new `MetadataFetcher.Identifier` case, one new `MetadataSource` case pair, one new `MetadataPersistenceOptions` field, light gating change in `AddByIdentifierView`, URL-override accepted by `PDFDownloadService`. No persistent `Reference` field changes, no `CKRecord` field changes, no migrations.
**Out of scope:** Web Import flow (`ClipperWebMetadataExtractor` / `WebImportView`), bulk URL import, browser extension / share sheet, JavaScript-rendered pages requiring WebKit, generic non-paper webpage scraping, the two pre-existing BibTeX-importer bugs called out at the bottom of this spec.

## Problem

Today the Add-by-Identifier paste box (`AddByIdentifierView` → `MetadataResolver.resolveManualEntry` → `MetadataFetcher.extractIdentifier`) recognizes only DOI, arXiv ID, PMID, PMCID, ISBN, or a paper title. When a user pastes one of these URLs:

- `https://openreview.net/forum?id=ABCD` (no DOI)
- `https://aclanthology.org/2024.acl-long.123/` (DOI in page, not in URL)
- `https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html` (no DOI anywhere)
- `https://proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Conference.html` (no DOI)
- `https://proceedings.mlr.press/v200/foo23a.html` (no DOI)

…the input is not recognized as a paper. `extractIdentifier` returns `nil` and the pipeline falls through to a title-search-on-URL-string, which never matches. The user either gives up or copies the title manually and re-pastes.

The Web Import flow (`ClipperWebMetadataExtractor`) is the wrong tool: it runs Defuddle/Readability on the page in a hidden `WKWebView`, produces a `referenceType: .webpage` Reference (intended for blog posts and news articles), and is Mac-only by linkage to `WebKit`.

## Goals

- Pasting a paper landing-page URL into Add-by-Identifier produces an authoritative `Reference` (article / conference paper) on the same path as a pasted DOI.
- Direct-PDF URLs from the same sites work too (rewritten to landing page, then scraped).
- Feature works in both the Mac app and `rubien-cli` — implementation lives in `RubienCore`, no `WebKit` dependency, pure `URLSession` + HTML parsing.
- New sites with `<meta name="citation_*">` tags need minimal code to add — only an entry in the host allowlist plus a path pattern.
- URL canonicalization is explicit and centralized, so classification routing is deterministic regardless of `www.` prefix, `http` vs `https`, trailing slashes, or fragments.
- No new persistent `Reference` fields; no new `CKRecord` fields; no migrations.

## Non-goals

- Reworking the Web Import flow for non-paper URLs.
- Building a generic "any URL → reference" extractor. URLs outside the path-shape allowlist fall through to today's identifier extraction or title-search.
- Fixing the two pre-existing BibTeX importer bugs (`@misc` → `.webpage`, no PDF-download offer in bulk BibTeX import). Flagged below as separate follow-ups.
- JavaScript-rendered pages. All target sites render `<meta>` tags server-side; we never need a headless browser.
- Caching scraped HTML beyond the existing 5-minute `responseCache` machinery.

## Design

### 1. Architecture

Three new files in `Sources/RubienCore/`, plus targeted edits to existing types:

```
RubienCore/Services/
├── RubienHTTPClient.swift       (NEW — shared User-Agent + retry + URLSession seam)
├── PaperURLResolver.swift       (NEW — orchestrator: classify, canonicalize, dispatch)
├── CitationMetaScraper.swift    (NEW — generic <meta name="citation_*"> parser)
└── MetadataFetcher.swift        (EDIT — use RubienHTTPClient; add Identifier.paperURL case)

RubienCore/Models/
└── MetadataVerification.swift   (EDIT — add MetadataPersistenceOptions.preferredPDFURL)

RubienCore/Services/
└── MetadataResolution.swift     (EDIT — add MetadataSource cases)
```

**Why `RubienHTTPClient`** — `MetadataFetcher.userAgent` (line 49) and `MetadataFetcher.withRetry` (line 1161) are both `private static`. We refuse to either (a) duplicate them in `CitationMetaScraper` (drift hazard) or (b) raise their access level (leaks implementation detail). Extract a small file-private-or-internal HTTP helper that owns both responsibilities and inject it where needed. `MetadataFetcher` becomes its first caller; `CitationMetaScraper` becomes its second. ~80 LoC.

**Why `MetadataPersistenceOptions.preferredPDFURL`** — Codex correctly flagged that threading a transient `scrapedPDFURL` through `VerifiedEnvelope` / `AuthoritativeMetadataRecord` would pollute structures meant only for `reference` + `evidence`. The codebase already has a precedent for "import-time data that doesn't belong on `Reference`": `MetadataPersistenceOptions.preferredPDFPath` (`MetadataVerification.swift:402`). Add a sibling `preferredPDFURL: String?` and use it. No envelope changes.

Flow when user pastes `https://openreview.net/forum?id=ABCD`:

```
AddByIdentifierView
  └─> MetadataResolver.resolveManualEntry(text)
        └─> MetadataFetcher.extractIdentifier(text)
              KnownPaperHost.classify(url)  // host + path-shape allowlist
              returns .paperURL(URL)        // only if path matches a known shape
        └─> MetadataResolver.resolveIdentifierLocally(.paperURL(url), ...)
              └─> PaperURLResolver.resolve(url, http: RubienHTTPClient)
                    ├─ normalize URL (host lowercase, www. strip for matching only)
                    ├─ rewritePDFURLToLanding(url)        // per-host regex
                    ├─ if host == thecvf:  CVF BibTeX adapter (uses BibTeXImporter)
                    │  else:               CitationMetaScraper.fetch
                    ├─ if citation_doi present:
                    │       MetadataFetcher.fetchFromDOI(doi)            // canonical
                    │       titleSimilarity(scraped.title, crossref.title) >= 0.60
                    │         else fall back to scraper-only Reference  (silent
                    │         CrossRef-wrong-work safeguard; see §4)
                    │       MetadataResolution.mergeReference(           // primary
                    │         primary: crossrefRef, fallback: scraperRef) //   wins,
                    │                                                    //  scraper
                    │                                                    //  fills
                    │                                                    //  gaps
                    └─ return Outcome(reference, scrapedPDFURL)
        └─> MetadataResolver attaches scrapedPDFURL onto the
            MetadataPersistenceOptions value carried through the import flow
            (via the same channel that today carries preferredPDFPath)
        └─> verifyFetchedRecord — produces VerifiedEnvelope (treated like a direct
            identifier lookup; manual-confirmation evidence; envelopes unchanged)
  └─> AddByIdentifierView gates the "Also download PDF" toggle on
      (ref.canDownloadPDF || hasScrapedPDFURL); on Import calls
      onSave(reference, downloadPDF, pdfURLOverride)
  └─> PDFDownloadService — uses pdfURLOverride when non-nil (skipping its
      arXiv/OpenAlex resolution); else existing path.
```

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

#### 2.1 `RubienHTTPClient`

Single struct with one job: HTTP GET with the polite-pool User-Agent and the existing retry policy. Replaces the private members on `MetadataFetcher`.

```swift
public struct RubienHTTPClient: Sendable {
    public static var contactEmail: String = ""        // existing field migrated from MetadataFetcher

    public let session: URLSession
    public let userAgent: String

    public init(session: URLSession = .shared, contactEmail: String = RubienHTTPClient.contactEmail)

    public func fetchData(
        _ url: URL,
        timeout: TimeInterval = 15,
        accept: String? = nil
    ) async throws -> (Data, HTTPURLResponse)
}

public func withRetry<T>(
    maxAttempts: Int = 3,
    operation: () async throws -> T
) async throws -> T
```

- `contactEmail` migrates from `MetadataFetcher.contactEmail` to `RubienHTTPClient.contactEmail` (same purpose: CrossRef polite-pool mailto). `MetadataFetcher.contactEmail` becomes a forwarding shim for one release so existing callers keep working, then deprecated.
- The `session` field is the test seam — production uses `.shared`, tests can inject a stub `URLSession` or replace just `fetchData` via a sibling `URLProtocol`-based stub. (Decision deferred to implementation; spec only requires that the seam exists.)
- `withRetry` keeps the existing retry behavior verbatim (extract via copy-paste, not behavior change).

`MetadataFetcher.fetchFromDOI` / `fetchFromArXiv` / etc. refactor to call `RubienHTTPClient.fetchData(...)`. Net new lines in `MetadataFetcher` after refactor: zero or negative.

#### 2.2 `CitationMetaScraper`

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
    public var pdfURL: String?            // resolved against landing URL; never relative
    public var publisher: String?
}

public enum CitationMetaScraper {
    public static func fetch(
        _ url: URL,
        http: RubienHTTPClient = RubienHTTPClient()
    ) async throws -> CitationMetaResult

    /// Pure-string variant for unit tests — no network.
    public static func parse(
        html: String,
        baseURL: URL
    ) -> CitationMetaResult
}
```

Implementation notes:
- HTML parsing is a scanner over the `<head>` region, not a DOM parser. `<meta>` tags in `<head>` are flat across all target sites.
- `<title>` tag used as fallback when `citation_title` is absent (some sites only expose `<title>`).
- `citation_author` collected in document order; `AuthorName.parseList` handles "Lastname, Firstname" format.
- `citation_publication_date` accepts `2024/06/12`, `2024-06-12`, or bare `2024`. Extract year. `citation_year` preferred if present.
- `citation_abstract` is rare; `og:description` more common but sometimes truncated. Prefer `citation_abstract` when both present.
- **Relative `citation_pdf_url` resolution:** Many ACM and IEEE pages serve a relative path (`/doi/pdf/10.1145/...`). `CitationMetaScraper.parse` resolves with `URL(string: relativePath, relativeTo: baseURL)?.absoluteString`. Only an absolute URL ever appears in `CitationMetaResult.pdfURL`. Same treatment for `citation_abstract_html_url` if we ever consume it.
- **Content-type check:** `fetch` rejects responses whose `Content-Type` is not `text/html` (or starts with `text/html`). Catches the "user pasted a PDF URL but the server returned a binary stream" case before HTML parsing.
- **Redirect tracking:** the final URL after redirects (from `HTTPURLResponse.url`) is the `baseURL` passed to `parse`, so relative `citation_pdf_url` values resolve against the page actually rendered, not the URL the user pasted.
- The scraper does **not** infer `referenceType` — that's the orchestrator's job (it knows the host).

#### 2.3 `PaperURLResolver`

Stateless enum, no shared mutable state, no caching of its own (`MetadataFetcher.responseCache` already caches CrossRef calls).

```swift
public enum PaperURLResolver {
    public struct Outcome: Sendable {
        public let reference: Reference
        public let scrapedPDFURL: String?
    }

    public static func resolve(
        _ url: URL,
        http: RubienHTTPClient = RubienHTTPClient()
    ) async throws -> Outcome
}
```

Three responsibilities:

**A. Host + path-shape classification** — `KnownPaperHost` enum.

```swift
internal enum KnownPaperHost: CaseIterable {
    case openReview, aclAnthology, cvfOpenAccess
    case neurIPS, pmlr, ieeeXplore, acmDL
    case nature, springer, scienceDirect

    static func classify(_ url: URL) -> KnownPaperHost?
}
```

`classify` returns non-nil **only when both host AND path match** a known shape. URLs like `https://link.springer.com/search?q=foo` correctly return nil and fall through to existing identifier extraction. URL canonicalization (§2.4) is applied before matching.

Per-host path patterns (initial set; extensible without code change to other layers):

| Host | Landing path regex | PDF path regex |
|---|---|---|
| `openreview.net` | `^/forum$` (requires `?id=…`) | `^/pdf$` (requires `?id=…`) |
| `aclanthology.org` | `^/\d{4}\.[a-z]+-(long\|short\|industry\|tutorial\|demo\|main\|findings)\.\d+/?$` | `^/\d{4}\.[a-z]+-(long\|short\|industry\|tutorial\|demo\|main\|findings)\.\d+\.pdf$` |
| `openaccess.thecvf.com` | `^/content/[^/]+/html/.+\.html$` | `^/content/[^/]+/papers/.+\.pdf$` |
| `papers.nips.cc` | `^/paper/\d+/hash/.+\.html$` | `^/paper/\d+/file/.+\.pdf$` |
| `proceedings.neurips.cc` | `^/paper_files/paper/\d+/hash/.+\.html$` | `^/paper_files/paper/\d+/file/.+\.pdf$` |
| `proceedings.mlr.press` | `^/v\d+/[^/]+\.html$` | `^/v\d+/[^/]+/[^/]+\.pdf$` |
| `ieeexplore.ieee.org` | `^/(document\|abstract/document)/\d+/?$` | `^/stamp/stamp\.jsp$` |
| `dl.acm.org` | `^/doi/(abs/)?10\.\d+/.+$` | `^/doi/pdf/10\.\d+/.+$` |
| `nature.com` (incl `www.`) | `^/articles/.+$` | `^/articles/.+\.pdf$` |
| `link.springer.com` | `^/(article\|chapter\|book\|referenceworkentry)/.+$` | `^/content/pdf/.+\.pdf$` |
| `www.sciencedirect.com` | `^/science/article/(pii\|abs/pii)/.+$` | `^/science/article/.+/pdfft$` |

`KnownPaperHost.classify` returns nil if the URL host is on the list but the path matches neither the landing nor PDF regex. The PDF regex is consulted only to know "this is a PDF URL needing rewrite" — the same path eventually goes through the landing path after rewrite.

**B. PDF-URL → landing-page rewrite** — per-host string substitution.

| Input PDF URL | Rewritten landing URL |
|---|---|
| `openreview.net/pdf?id=ABCD` | `openreview.net/forum?id=ABCD` |
| `aclanthology.org/2024.acl-long.123.pdf` | `aclanthology.org/2024.acl-long.123/` |
| `openaccess.thecvf.com/.../papers/Foo.pdf` | `openaccess.thecvf.com/.../html/Foo.html` |
| `papers.nips.cc/paper/2024/file/abc.pdf` | `papers.nips.cc/paper/2024/hash/abc.html` (filename keep, ext swap) |
| `proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Conference.pdf` | `proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Conference.html` (with `Paper`→`Abstract` substitution) |
| `proceedings.mlr.press/v200/foo23a/foo23a.pdf` | `proceedings.mlr.press/v200/foo23a.html` |
| `dl.acm.org/doi/pdf/10.1145/foo` | `dl.acm.org/doi/10.1145/foo` |
| `nature.com/articles/foo.pdf` | `nature.com/articles/foo` |
| `link.springer.com/content/pdf/10.1007/foo.pdf` | `link.springer.com/article/10.1007/foo` (DOI-to-article path) |
| `www.sciencedirect.com/science/article/pii/SXXXX/pdfft` | `www.sciencedirect.com/science/article/pii/SXXXX` |

Some rewrites are not lossless (notably NeurIPS's `Paper`→`Abstract` filename component) and depend on conference-specific conventions; the implementation must handle the case where the rewritten URL returns 404 with the §4 error row "PDF-URL rewrite produces a URL we then fail to fetch".

If the input URL is already a landing URL, the function returns it unchanged.

**C. Dispatch and post-processing**

Algorithm in `PaperURLResolver.resolve`:

1. Apply URL canonicalization (§2.4).
2. Classify host. If `nil`, throw (defensive — the orchestrator is only called via the `.paperURL` branch which already ran classification, but `classify` is idempotent).
3. Rewrite PDF URL to landing URL if applicable.
4. If host == `.cvfOpenAccess`, run the CVF BibTeX adapter (described in §3 Case C). Otherwise, run `CitationMetaScraper.fetch`.
5. Build a draft `Reference` from the scraper / BibTeX result. `referenceType` chosen from host:
   - `.cvfOpenAccess`, `.neurIPS`, `.pmlr` → `.conferencePaper`.
   - `.openReview` → `.conferencePaper`.
   - `.aclAnthology` → `.conferencePaper` if `citation_conference_title` present, else `.journalArticle`.
   - `.ieeeXplore`, `.acmDL`, `.nature`, `.springer`, `.scienceDirect` → `.journalArticle` if `citation_journal_title` present, else `.conferencePaper` if `citation_conference_title`, else `.journalArticle` as default.
6. **Insufficient-evidence gate.** Reject (caller surfaces `.rejected(insufficientEvidence)`) if the draft has fewer than 2 of: non-empty title, ≥1 author, year, journal-or-conference-title.
7. If `result.doi` is non-nil, call `MetadataFetcher.fetchFromDOI(doi)`.
   - **On success**, compute `MetadataResolution.titleSimilarity(scraped.title, crossref.title)`. If ≥ 0.60, **use CrossRef as primary and scraper as fallback** via `MetadataResolution.mergeReference(primary: crossref, fallback: scraper)`. If < 0.60, log via `resolverTrace("paperURL: DOI-title mismatch …")` and **fall back to scraper-only**. The 0.60 threshold matches the existing book title-search threshold in `MetadataResolver.refreshWithBookTitleSearch`.
   - **On failure** (network / 5xx / parse), log and use scraper-only Reference. CrossRef outages remain non-fatal.
8. `Reference.url` is set to the **landing-page URL** (post-rewrite, post-canonicalization but with original case preserved on the path/query). "Open original" affordances point to the publisher page, never to a `doi.org` redirect.
9. `Reference.metadataSource` is set to one of:
   - `.cvfOpenAccess` (NEW) — when the CVF BibTeX adapter produced the Reference.
   - `.publisherCitationMeta` (NEW) — for every other case (citation_* scraper produced the Reference, regardless of whether DOI re-fetch happened or not).

   Note: CrossRef-fetched references continue to be labeled with the existing `.translationServer` source (current behavior preserved). We are **not** introducing a `.crossref` case in this spec. Rationale: doing so would mean either backfilling existing rows (out of scope) or accepting a "DOI route uses `.translationServer`, paper-URL route uses something else" inconsistency. Cleaner to label *the new code paths only*.

10. Return `Outcome(reference, scrapedPDFURL: result.pdfURL)`. `scrapedPDFURL` is always an absolute URL (relative paths were resolved in §2.2).

#### 2.4 URL canonicalization rules

A single function `PaperURLResolver.canonicalize(_ url: URL) -> URL` applied **only for classification and host matching**. The original URL the user pasted (trimmed of surrounding whitespace) is what eventually lands on `Reference.url`, so "open original" reflects the user's input rather than our normalized form. Canonicalization is purely an internal routing tool.

Rules:

| Aspect | Rule | Notes |
|---|---|---|
| Scheme | Lowercase. Reject if not `http` or `https`. | RFC 3986 §3.1. |
| Host | Lowercase. | URL hosts are case-insensitive. |
| `www.` prefix | Strip for matching only. | Canonical form: `nature.com` matches both `nature.com` and `www.nature.com`. Allowlist entries stored without `www.`. |
| Default ports | Strip `:80` for http, `:443` for https. | None of our publishers use non-standard ports; safe to canonicalize. |
| Fragment | Strip. | `#section-2` is client-side only; never part of routing. |
| Trailing slash on path | **Preserve.** Path regex must accept both forms (`/foo` and `/foo/`). | Some path patterns require a slash (ACL), others don't (NeurIPS). |
| Path case | Preserve. | Paths are case-sensitive per RFC 3986 §3.3. |
| Query parameter order | Preserve as-is. | OpenReview routing depends on `?id=…`; we don't reorder. |
| Query parameter case | Preserve. | Same rationale. |
| Percent-encoding | Preserve. | Don't decode-then-re-encode; publishers occasionally encode meaningful chars (`+` in arXiv categories). |
| http vs https | Equivalent for matching; pass through original for fetch. | If publisher upgrades http→https via redirect, our `RubienHTTPClient` follows it automatically. |

Edge cases:
- **`URL(string:)` rejects malformed percent-encoding.** Already rejected upstream as "not a valid URL"; caller surfaces existing error. No special handling here.
- **Internationalized domain names (IDN).** Out of scope — none of our target publishers use IDN hosts. If `Foundation.URL` returns the Punycode form for an IDN, host matching may silently fail; we explicitly accept that as out-of-scope.
- **URL with embedded credentials (`user:pass@host`).** Reject — none of our publishers require basic auth; URLs with credentials are almost certainly hostile. `classify` returns nil.

#### 2.5 `MetadataFetcher.extractIdentifier` — extended

```swift
public static func extractIdentifier(from text: String) -> Identifier? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // NEW: paper landing-page URL on a known host with a known path shape.
    // Placed before DOI extraction so URLs like
    //   https://link.springer.com/article/10.1007/s11042-024-12345-6
    // route through PaperURLResolver (which preserves the landing URL on
    // Reference.url) rather than the bare DOI extractor (which would route
    // straight to CrossRef and lose the publisher landing-page context).
    //
    // The classifier requires BOTH host AND path to match — URLs like
    //   https://link.springer.com/search?q=foo
    // fall through to existing extraction below.
    if let url = URL(string: trimmed),
       let scheme = url.scheme?.lowercased(),
       (scheme == "http" || scheme == "https"),
       KnownPaperHost.classify(url) != nil {
        return .paperURL(url)
    }

    // ... existing PMCID-URL / DOI / arXiv / ISBN / PMID checks unchanged ...
}
```

The path-shape gate (not host-only) means we don't capture every URL on these hosts. URLs that hit an allowlisted host but unfamiliar path correctly fall through, preserving existing behavior for non-paper URLs (e.g. Springer search pages, IEEE journal homepages).

#### 2.6 `MetadataResolver.resolveIdentifierLocally` — extended

```swift
case .paperURL(let url):
    let outcome = try await PaperURLResolver.resolve(url)
    reference = outcome.reference
    // scrapedPDFURL flows out via MetadataResolutionResult's existing
    // channel (the calling code already creates MetadataPersistenceOptions
    // when persisting; we add preferredPDFURL alongside preferredPDFPath).
    scrapedPDFURL = outcome.scrapedPDFURL
```

The exact mechanism for getting `scrapedPDFURL` from `resolveIdentifierLocally` out to the UI:

- `resolveIdentifierLocally` already returns a `MetadataResolutionResult`. We carry the URL on the `VerifiedEnvelope` *only* via an out-of-band side channel — a private `[ReferenceID: String]` map on `MetadataResolver`? — no, that's worse than threading.
- **Cleaner:** Extend `MetadataResolutionResult.verified` to carry `preferredPDFURL: String?` alongside its envelope, as a new associated value at the result level rather than inside `VerifiedEnvelope`. The envelope itself stays unchanged (it remains the canonical "this is the verified Reference + its evidence" type, shared with persistence and queue paths). The `.verified` *result case* gets the extra optional.

  ```swift
  public enum MetadataResolutionResult: Sendable {
      case verified(VerifiedEnvelope, preferredPDFURL: String? = nil)  // NEW associated value
      case candidate(CandidateEnvelope)
      case blocked(BlockedEnvelope)
      case seedOnly(IntakeEnvelope)
      case rejected(RejectedEnvelope)
  }
  ```

  This is a discriminated-union extension, not an envelope contamination. Pattern matching at all call sites is exhaustive in Swift, so the compiler will surface every site that needs the new value. Existing call sites get `preferredPDFURL: nil` by default and ignore it.

- `AddByIdentifierView` reads `preferredPDFURL` off the `.verified` case and passes it to `onSave(reference, downloadPDF, pdfURLOverride: preferredPDFURL)`.
- The eventual call to persist via `AppDatabase` sets `MetadataPersistenceOptions.preferredPDFURL = pdfURLOverride`, mirroring how `preferredPDFPath` is threaded today.

This keeps the envelope shape stable (good for the persistence/queue/retry surface that already consumes it) while making the new data first-class at the result level (where it belongs — it's a property of *how we resolved this particular request*, not of the reference itself).

#### 2.7 `Reference.canDownloadPDF` and `AddByIdentifierView` toggle gating

`Reference.canDownloadPDF` (`Reference.swift:381`) currently returns `true` only for DOI or `arxiv.org/abs/`-bearing references. We do **not** modify it — that property is consumed in many places and reflects "does this reference, by itself, have enough data to find a PDF later?" which remains true.

Instead, **`AddByIdentifierView` gates the toggle on the combined condition**:

```swift
Toggle(...)
    .disabled(!ref.canDownloadPDF && preferredPDFURL == nil)
```

For OpenReview/CVF/PMLR papers without a DOI, `canDownloadPDF` is false but `preferredPDFURL` is non-nil → toggle enabled. For DOI-bearing references with no scraped URL, behavior unchanged.

#### 2.8 `PDFDownloadService.downloadPDF` — URL override

Today (`PDFDownloadService.swift:97`) the service resolves arXiv via the abstract URL and DOIs via OpenAlex. Add an override:

```swift
public func downloadPDF(
    for reference: Reference,
    overrideURL: String? = nil
) async throws -> URL {
    if let override = overrideURL?.rubien_nilIfBlank,
       let url = URL(string: override) {
        return try await downloadAndStore(url, reference: reference)
    }
    // existing arXiv / OpenAlex resolution unchanged
}
```

When an override is provided, skip resolution entirely and fetch directly. Hashing, storage, and `PDFAssetCache` writes are unchanged — they're independent of where the URL came from.

### 3. Data flow — three representative cases

**Case A — OpenReview landing page** (no DOI):

```
input: https://openreview.net/forum?id=ABCD
 1. KnownPaperHost.classify -> .openReview (host + path match)
 2. extractIdentifier -> .paperURL(URL)
 3. PaperURLResolver.resolve
      canonicalize: lowercase host (already lc), no www, no fragment
      rewritePDFURLToLanding: no-op (already landing)
      CitationMetaScraper.fetch -> CitationMetaResult
        { title: "...", authors: [...], year: 2024,
          conferenceTitle: "ICLR 2024", abstract: "...",
          pdfURL: "https://openreview.net/pdf?id=ABCD" }   // resolved absolute
      doi == nil -> build Reference directly
        referenceType = .conferencePaper
        metadataSource = .publisherCitationMeta
        url = "https://openreview.net/forum?id=ABCD"      // original user input
 4. Outcome(reference, scrapedPDFURL: "https://openreview.net/pdf?id=ABCD")
 5. MetadataResolver returns .verified(envelope, preferredPDFURL: "<pdf url>")
 6. AddByIdentifierView: ref.canDownloadPDF == false BUT preferredPDFURL != nil
    -> toggle enabled, user clicks Import
 7. onSave(reference, downloadPDF: true, pdfURLOverride: "<pdf url>")
 8. PDFDownloadService.downloadPDF(for: reference, overrideURL: "<pdf url>")
    downloads directly, hashes, stores via PDFAssetCache
```

**Case B — ACL Anthology direct-PDF URL** (DOI present):

```
input: https://aclanthology.org/2024.acl-long.123.pdf
 1. KnownPaperHost.classify -> .aclAnthology (PDF path matched)
 2. extractIdentifier -> .paperURL(URL)
 3. PaperURLResolver.resolve
      canonicalize: no change
      rewritePDFURLToLanding -> https://aclanthology.org/2024.acl-long.123/
      CitationMetaScraper.fetch (on landing)
        { ..., doi: "10.18653/v1/2024.acl-long.123",
          pdfURL: "https://aclanthology.org/2024.acl-long.123.pdf" }
      doi present -> MetadataFetcher.fetchFromDOI("10.18653/v1/...")
        titleSimilarity(scraped.title, crossref.title) >= 0.60 -> use CrossRef
        MetadataResolution.mergeReference(primary: crossrefRef, fallback: scraperRef)
          (CrossRef supplies title/authors/year/journal/pages/volume; scraper
           supplies abstract and conference_title gap-fills if any)
        reference.url = "https://aclanthology.org/2024.acl-long.123/"
        reference.metadataSource = .publisherCitationMeta
        scrapedPDFURL preserved
 4..8 same as Case A
```

**Case C — CVF Open Access** (no citation_* meta):

```
input: https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html
 1. KnownPaperHost.classify -> .cvfOpenAccess (landing path matched)
 2. extractIdentifier -> .paperURL(URL)
 3. PaperURLResolver.resolve
      canonicalize: no change
      host == .cvfOpenAccess -> CVF BibTeX adapter:
        - GET landing page via RubienHTTPClient
        - Extract <pre>...</pre> contents via regex on response body
          (CVF pages contain exactly one <pre> block carrying the BibTeX)
        - Parse with BibTeXImporter.parse -> [Reference]
          Take first. If array empty or first.title is blank, throw
          extraction failure (§4 row "BibTeX block found but Reference
          has empty title")
        - Synthesize pdfURL by deterministic substitution:
            ".../html/Foo_paper.html" -> ".../papers/Foo_paper.pdf"
      Reference{ referenceType: .conferencePaper,
                 journal: "Proceedings of the IEEE/CVF Conference...",
                 eventTitle: same (set by BibTeXImporter when entryType
                                   == "inproceedings"),
                 url: "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html",
                 metadataSource: .cvfOpenAccess }
 4..8 same as Case A
```

### 4. Error handling

Same `MetadataResolutionResult` machinery; no new envelope types. Expanded error table:

| Condition | Result | User-facing message |
|---|---|---|
| URL host not in allowlist | falls through `extractIdentifier`; existing title-search path applies | (unchanged) |
| URL host in allowlist but path does not match a known shape | falls through `extractIdentifier`; existing identifier extraction applies | (unchanged — Springer search pages etc. handled as today) |
| URL has embedded credentials (`user:pass@host`) | `KnownPaperHost.classify` returns nil → falls through | (unchanged) |
| Allowlisted host, GET returns 4xx/5xx | `.rejected(insufficientEvidence)` | "Could not load <host> page (HTTP <code>). Check the URL or try a DOI." |
| Response `Content-Type` not `text/html` | `.rejected(insufficientEvidence)` | "Expected an HTML page; the URL returned <type>. Paste the abstract/landing page URL instead of the PDF." |
| HTTP redirect to a host **not** on the allowlist | `.rejected(insufficientEvidence)` | "Page redirected to <new-host>, which may require login. Try the canonical landing URL." |
| Response 200, HTML, but contains a login/paywall block (heuristic: no `citation_*` tags AND title contains "Sign in" / "Subscribe" / "Access through your institution") | `.rejected(insufficientEvidence)` | "Page appears to require login. Open it in your browser and copy the DOI." |
| Allowlisted host + path, GET succeeds, scraper extracts < 2 useful fields (title + at least one of authors/year/journal/conferenceTitle) | `.rejected(insufficientEvidence)` | "Page did not expose paper metadata. Try pasting the DOI or paper title." |
| Scraper produces DOI, CrossRef call fails (network / 5xx / parse) | **fall through** — return scraper-only Reference; log via `resolverTrace`. Not an error. | (no error surfaced) |
| Scraper produces DOI, CrossRef succeeds, but `titleSimilarity(scraped, crossref) < 0.60` | **fall through** — return scraper-only Reference; log warning. The DOI is preserved on the Reference (it may still be correct; only the title-mismatch is suspicious). | (no error surfaced; protects against silent corruption from a chapter-vs-book DOI mismatch) |
| Network timeout (15s, matches existing `MetadataFetcher` timeout) | `.rejected(insufficientEvidence)` | `error.localizedDescription` |
| CVF page returns 200 but no `<pre>` BibTeX block matches | `.rejected(insufficientEvidence)` | "Could not find BibTeX on this CVF page. The page format may have changed." |
| BibTeX block found, `BibTeXImporter.parse` returns empty array or first Reference has blank title | `.rejected(insufficientEvidence)` | "Found BibTeX but it did not contain usable fields." |
| PDF-URL rewrite produces a URL we then fail to fetch (404 on rewritten landing URL) | `.rejected(insufficientEvidence)` | "Loaded PDF URL but no matching landing page. Try the abstract page URL." |
| Malformed URL string (`URL(string:) == nil`) | falls through `extractIdentifier`; existing title-search applies | (unchanged) |

Two policies encoded above:

- **CrossRef-fail is non-fatal.** A scraped Reference with DOI degrades to scraper-only when CrossRef hiccups. CrossRef outages happen; users keep moving.
- **Title-similarity-fail is non-fatal but degraded.** When CrossRef returns a paper with a title that doesn't match the scraped title (≥ 0.40 difference by `MetadataResolution.titleSimilarity`), trust the scraper's `Reference` (it came from the publisher page the user is actually looking at) and log the mismatch. This protects against the chapter-vs-book DOI bug where a DOI redirects to its parent record.
- **No fallback to title-search.** When a paper URL fails extraction, we don't silently re-query OpenAlex by the page `<title>`. Silent re-routing is confusing UX.

**Concurrency note.** `PaperURLResolver` is a stateless enum and holds no caches. Duplicate concurrent calls for the same URL are independent (each does its own HTTP and CrossRef calls). `MetadataFetcher.responseCache` already deduplicates concurrent CrossRef calls within its TTL. If the user double-clicks Import, the worst case is one extra HTML fetch.

### 5. Testing

All new tests live in `RubienCoreTests` (fastest target; no SwiftUI dep). No new test target.

**Pure unit tests (no network)**

1. **`KnownPaperHostClassifyTests.swift`** — host + path classification table tests.
   - For each of the 10 hosts: at least 3 positive landing URLs (varying valid path shapes), at least 1 positive PDF URL, at least 2 negative URLs (host matches, path doesn't — e.g. Springer search, IEEE journal homepage).
   - Negative table: URLs from random hosts → nil.
   - Canonicalization edge cases as their own test method: `www.` prefix, mixed-case host, http vs https, fragment present, trailing slash variants, default port, embedded credentials → rejected.

2. **`PaperURLRewriteTests.swift`** — PDF → landing rewrite table tests.
   - Per-host: input PDF URL → expected landing URL.
   - Edge cases: PDF URL with query string preserved into landing? (Yes for OpenReview; not for ACL.) Documented per host.

3. **`CitationMetaScraperParseTests.swift`** — `parse(html:baseURL:)` over captured fixtures.
   - Fixture files in `Tests/RubienCoreTests/Fixtures/CitationMeta/`:
     - `openreview-forum.html` (no DOI)
     - `aclanthology-paper.html` (with `citation_doi`)
     - `neurips-proceedings.html`
     - `pmlr-paper.html`
     - `ieee-xplore.html`
     - `nature-article.html`
     - `springer-chapter.html`
     - `acm-dl.html`
     - `sciencedirect-article.html`
   - Each fixture header-commented with source URL and capture date.
   - Each test feeds fixture HTML to `parse`, asserts every populated field.
   - **Relative `citation_pdf_url` test:** ACM/IEEE fixtures contain relative PDF URLs; assert that the parser's output `pdfURL` is the absolute resolved form.
   - **`citation_pdf_url` missing test:** at least one fixture without a PDF URL; assert `pdfURL == nil`.
   - Negative fixtures:
     - `partial-meta-only-title.html` — result has only title.
     - `no-citation-meta.html` — empty result.
     - `malformed-meta.html` (unclosed tags, weird encoding) — doesn't crash; partial result OK.
     - `paywall-login-page.html` — scraper extracts < 2 useful fields; orchestrator rejects (covered in §5 integration tests).

4. **`BibTeXImporterCVFTests.swift`** — closes the gap that `BibTeXImporter.parse(_:)` has no direct unit tests.
   - 6–10 real CVF BibTeX blocks from current CVPR/ICCV/WACV/ECCV pages, asserted field-by-field.
   - Specific cases:
     - Standard CVPR `@InProceedings` (5+ authors).
     - Title with LaTeX brace protection (`{S}^n`-style).
     - `month = june` (bare word, not number).
     - Block followed by HTML noise (mimics `<pre>` extraction surrounded by page markup).
     - Block without `doi` field (CVF typically omits).
     - Multi-line title (line-wrapped, real BibTeX quirk).

**Orchestrator tests with injected transport**

5. **`PaperURLResolverTests.swift`** — `resolve(url, http:)` with a stubbed `RubienHTTPClient`.
   - Stub `RubienHTTPClient` allows seeding `(URL) → (Data, HTTPURLResponse)` responses. Either implement via a custom `URLProtocol` subclass registered for `URLSession(configuration:)`, or inject a closure-based fetcher. Decision deferred to implementation; spec requires only that orchestration is testable without real network.
   - Scenarios:
     - OpenReview landing → fixture HTML → expect Outcome with citation_*-derived Reference, conferenceType, scrapedPDFURL absolute.
     - ACL PDF URL → rewrite to landing → fixture HTML with DOI → CrossRef stub returns matching JSON → expect merged Reference, metadataSource `.publisherCitationMeta`.
     - ACL PDF URL → CrossRef stub returns 503 → expect scraper-only Reference (CrossRef-fail non-fatal).
     - ACL PDF URL → CrossRef stub returns a paper with different title (titleSimilarity < 0.60) → expect scraper-only Reference, logged warning.
     - CVF landing → fixture HTML containing `<pre>` BibTeX → expect Reference from BibTeXImporter, pdfURL synthesized.
     - PDF URL rewrite → rewritten URL returns 404 → expect `.rejected`.
     - HTML content-type check → response with `application/pdf` → expect `.rejected`.
     - Redirect-to-unrelated-host → response chain redirects from openreview.net to evil.example.com → expect `.rejected`.
     - Paywall heuristic → response HTML has no `citation_*` tags and title contains "Sign in" → expect `.rejected`.

**Extraction-level tests**

6. **`PaperURLExtractionTests.swift`** — `MetadataFetcher.extractIdentifier` cases.
   - `https://openreview.net/forum?id=ABCD` → `.paperURL`.
   - `https://openreview.net/pdf?id=ABCD` → `.paperURL`.
   - `https://aclanthology.org/2024.acl-long.123/` → `.paperURL`.
   - `https://www.nature.com/articles/s41586-024-12345-6` → `.paperURL`.
   - `https://link.springer.com/article/10.1007/s11042-024-12345-6` → `.paperURL` (verifies path-shape gate routes through resolver despite embedded DOI substring).
   - `https://link.springer.com/search?q=neural` → `.nil` (host matches, path doesn't; falls through; no DOI in URL, so existing identifier extraction returns nil too).
   - `https://example-blog.com/post/hello` → `.nil`.
   - `10.1234/abc` (bare DOI, not URL) → existing `.doi(...)` unchanged (regression coverage).
   - Canonicalization regression: `HTTP://WWW.NATURE.COM/articles/...` (uppercase scheme/host) → `.paperURL` after canonicalization.

**Integration tests with stubbed network**

7. **`MetadataResolverPaperURLTests.swift`** — end-to-end through `MetadataResolver.resolveManualEntry`.
   - One success test per adapter family (citation_*, citation_*+DOI, CVF BibTeX) — verify `.verified` result with `preferredPDFURL` populated.
   - One failure-path test per error-table row in §4.
   - `Reference.url` is the landing-page URL after rewrite, regardless of CrossRef substitution.
   - `MetadataPersistenceOptions.preferredPDFURL` reaches `AppDatabase` persistence (covered by an existing-path test or a new one).

**Live smoke tests (gated)**

8. **`PaperURLLiveSmokeTests.swift`** — opt-in via env var `RUBIEN_LIVE_TESTS=1`. Skipped in CI by default.
   - For each of the 10 hosts: fetch a known stable URL, assert the parser produces at least `{ title, authors, year }`. Doesn't assert exact field values (sites edit their pages); just smokes that meta tags are still there.
   - A companion script `Scripts/refresh-citation-fixtures.sh` re-captures `<head>` from each smoke URL into the fixture directory, with a manual diff step. Run by a maintainer when smoke tests start failing.

**Tests we are NOT writing (and why)**

- **CLI integration tests** — `rubien-cli add` already exercises `resolveManualEntry`. If unit tests pass, CLI works. No new JSON contract surface.
- **SwiftUI snapshot tests** on `AddByIdentifierView` — view layer change is "gate toggle on `||` condition + thread one extra optional argument". Not visual-regression-worthy.
- **`RubienSyncTests`** — no `Reference` model field changes, no `CKRecord` field changes. New `MetadataSource` cases follow the existing forward-compatible decode pattern (`ReferenceRecord.swift:232`).

**Fixture rot mitigation**

- Each fixture file has a comment header noting source URL and capture date.
- `Tests/RubienCoreTests/Fixtures/CitationMeta/FIXTURE-NOTES.md` lists every site we depend on, the canonical meta-tag set we expect, and the refresh procedure.
- The gated live smoke tests are the early-warning system; the fixture-refresh script is the recovery tool.

## Implementation order

Each step is a self-contained commit that builds and passes its own tests:

1. **`RubienHTTPClient.swift`** — extract `userAgent` + `withRetry` from `MetadataFetcher` into a new shared helper. Refactor `MetadataFetcher.fetchFromDOI` / `fetchFromArXiv` / etc. to call it. Behavior-preserving. Adds no new feature; landed first so subsequent steps don't have to dance around private members.
2. **`BibTeXImporterCVFTests.swift`** — direct unit tests on existing importer with CVF fixtures. Locks in BibTeX behavior before we depend on it.
3. **`CitationMetaScraper.swift`** + `CitationMetaScraperParseTests.swift` with fixtures + relative-URL resolution. Pure logic + parser + transport via `RubienHTTPClient`.
4. **`PaperURLResolver.swift`** — `KnownPaperHost.classify` (host + path), URL canonicalization, PDF→landing rewrite, dispatch. With `KnownPaperHostClassifyTests.swift`, `PaperURLRewriteTests.swift`, `PaperURLResolverTests.swift`.
5. **Extend `MetadataFetcher.Identifier` and `extractIdentifier`** + `PaperURLExtractionTests.swift`.
6. **Extend `MetadataPersistenceOptions` with `preferredPDFURL`** + extend `MetadataResolutionResult.verified` with the associated value. Wire through `MetadataResolver.resolveIdentifierLocally` and `MetadataResolverPaperURLTests.swift`.
7. **Add `MetadataSource.cvfOpenAccess`** + **`.publisherCitationMeta`**. Trivial, no behavior change beyond labeling.
8. **UI thread-through:** `AddByIdentifierView` toggle gating; `PDFDownloadService.downloadPDF` URL override; placeholder caption updated to "Supports DOI · arXiv · PMID · PMCID · ISBN · paper URL · title".
9. **Gated live smoke tests + fixture refresh script.**

## Out-of-scope follow-ups (file separately)

Surfaced during this design but explicitly **not** addressed here:

- **`BibTeXImporter.swift:113`** — arXiv `@misc{}` entries import as `.webpage`. Should detect `archivePrefix = {arXiv}` / `eprint = {…}` / arxiv.org URL and return `.journalArticle` (or `.preprint` if added). Pre-existing bug; user-reported during this design's review.
- **Bulk BibTeX import has no "Also download PDF" affordance.** Bulk-import via `ContentView.swift:618` doesn't route through `AddByIdentifierView` and never offers the toggle. Pre-existing UX gap; user-reported during this design's review.
- **Backfilling `MetadataSource.crossref` for existing CrossRef-fetched references.** Today these are labeled `.translationServer`. This spec preserves that; a follow-up could add the case and migrate.
