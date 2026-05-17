# Paper landing-page URL resolver

**Status:** v5 — implementation-ready 2026-05-16 (after 4 rounds of Codex review)
**Scope:** Extend `MetadataResolver.resolveManualEntry` to recognize paper landing-page URLs (OpenReview, ACL Anthology, CVF Open Access, NeurIPS, PMLR, IEEE Xplore, ACM DL, Nature, Springer, ScienceDirect) and resolve them to authoritative `Reference` records, with optional PDF auto-download. Two new files in `RubienCore/Services/`, one new `MetadataFetcher.Identifier` case, two new `MetadataSource` cases, one new wrapper struct (`ManualEntryOutcome`) returned by `MetadataResolver.resolveManualEntry`, callback signature changes on the Add-by-Identifier UI path. No persistent `Reference` field changes, no `CKRecord` field changes, no `MetadataResolutionResult` enum shape changes, no migrations.
**Out of scope:** Web Import flow (`ClipperWebMetadataExtractor` / `WebImportView`), bulk URL import, browser extension / share sheet, JavaScript-rendered pages requiring WebKit, generic non-paper webpage scraping, shared HTTP client refactor of `MetadataFetcher` (two new HTTP callers do not warrant a refactor — see §1 rationale), the two pre-existing BibTeX-importer bugs called out at the bottom of this spec.

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
- Direct-PDF URLs from the same sites work too (rewritten to landing page, then scraped), except where the rewrite is unsafe (Springer — see §2.3.B).
- Feature works in both the Mac app and `rubien-cli` — implementation lives in `RubienCore`, no `WebKit` dependency, pure `URLSession` + HTML parsing.
- New sites with `<meta name="citation_*">` tags need minimal code to add — only an entry in the host allowlist plus path patterns.
- URL canonicalization is explicit and applied uniformly: the canonical form is stored on `Reference.url`, so duplicate detection (which uses exact-string match) does not split equivalent URLs across separate references.
- `MetadataResolutionResult` enum shape is unchanged: all 26 existing pattern-match sites continue to work as-is. The new resolution data (`preferredPDFURL`) flows through a sibling wrapper used only on the manual-entry path.
- No new persistent `Reference` fields; no new `CKRecord` fields; no migrations.

## Non-goals

- Reworking the Web Import flow for non-paper URLs.
- Building a generic "any URL → reference" extractor. URLs outside the path-shape allowlist fall through to today's identifier extraction or title-search.
- Fixing the two pre-existing BibTeX importer bugs (`@misc` → `.webpage`, no PDF-download offer in bulk BibTeX import). Flagged below as separate follow-ups.
- JavaScript-rendered pages. All target sites render `<meta>` tags server-side; we never need a headless browser.
- Caching scraped HTML beyond the existing 5-minute `responseCache` mechanism (which caches *completed* CrossRef results only; in-flight concurrent calls are not coalesced — see §4 concurrency note).
- Refactoring `MetadataFetcher` to use a shared HTTP client. `PDFDownloadService` also reads `MetadataFetcher.contactEmail` directly (`PDFDownloadService.swift:219`); a full shared-client extraction would touch three callers and risk behavior changes across the whole metadata path. For two new HTTP callers (`CitationMetaScraper`, `PaperURLResolver`'s CVF adapter), small local helpers with ~10 lines of duplication are acceptable per CLAUDE.md's "three similar lines is better than a premature abstraction" guidance. A future commit can extract a shared client if a fourth caller appears.

## Design

### 1. Architecture

Two new files in `Sources/RubienCore/Services/`, plus targeted edits to existing types:

```
RubienCore/Services/
├── PaperURLResolver.swift       (NEW — orchestrator: classify, canonicalize, dispatch)
├── CitationMetaScraper.swift    (NEW — generic <meta name="citation_*"> parser)
└── MetadataFetcher.swift        (EDIT — add Identifier.paperURL case)

RubienCore/Services/
└── MetadataResolution.swift     (EDIT — add MetadataSource cases)

Rubien/Services/                  (Mac-only)
└── MetadataResolver.swift       (EDIT — return ManualEntryOutcome from resolveManualEntry)
```

**Why no shared HTTP client.** v2 of this spec proposed extracting a `RubienHTTPClient` to share `userAgent` and `withRetry` with the existing `MetadataFetcher`. Reasons we backed off:

- `MetadataFetcher.userAgent` (private, `MetadataFetcher.swift:49`) is a 4-line computed property reading from public `MetadataFetcher.contactEmail`. Copying that inline costs 4 lines per caller. New callers: 2. Total: 8 lines of duplication.
- `MetadataFetcher.withRetry` (private, `MetadataFetcher.swift:1161`) is a ~30-line generic retry helper. Copying it once into a new file is acceptable; extracting it cleanly would require either making the existing copy public (leaks implementation detail) or refactoring both into a third location (touches the whole metadata path).
- `PDFDownloadService.fetchOpenAlexPDFURL` also reads `MetadataFetcher.contactEmail` directly (`PDFDownloadService.swift:219`). A clean extraction would need to migrate this too, expanding scope further.
- The fundamental win of extraction — one source of truth — already exists for `contactEmail`: `RubienApp.swift:82` configures `MetadataFetcher.contactEmail` at launch, and all callers (existing + new) read from that single public static.

So: new code references `MetadataFetcher.contactEmail` directly for the polite-pool mailto, inlines the User-Agent string format, and inlines a small retry helper. No new abstraction.

**Why no `MetadataResolutionResult` shape change.** v2 proposed extending `MetadataResolutionResult.verified` with a `preferredPDFURL: String?` associated value. Reasons we backed off:

- `.verified(` pattern matches in 26 sites across app, core, and tests (verified by grep). All would need updating from `case .verified(let env)` to `case .verified(let env, _)`. Mechanical but broad.
- The `preferredPDFURL` value is only meaningful on the manual-entry path. The persistence/queue/retry surface that consumes `MetadataResolutionResult` (`AppDatabase.swift:1622`, `BatchImportView.swift:238`, `ContentView.swift:1199`, `ContentView.swift:1410`) does not need it. Extending the enum forces every consumer to acknowledge a value it will never use.

Instead, `MetadataResolver.resolveManualEntry` returns a new wrapper:

```swift
public struct ManualEntryOutcome: Sendable {
    public let result: MetadataResolutionResult
    public let preferredPDFURL: String?    // populated only on .verified from paper-URL path
}
```

Other call sites that take `MetadataResolutionResult` directly (e.g. `MetadataResolver.resolveSeed`, `MetadataResolver.refreshReference`, `BatchImportView`, `AppDatabase`) are untouched.

**Why `preferredPDFURL` is callback-thread-only.** v2 also proposed adding `preferredPDFURL` to `MetadataPersistenceOptions`. That was wrong: `MetadataPersistenceOptions.preferredPDFPath` carries an *already-local filename* into a *synchronous DB transaction* (`AppDatabase.swift:1632, 1880`). A remote URL is the opposite shape — async, post-save, network-bound. It belongs on the existing UI background-task path (`ContentView.downloadPDFInBackground`), not in the DB options. So:

- `AddByIdentifierView.onSave` signature becomes `(Reference, downloadPDF: Bool, pdfURLOverride: String?)`.
- `ContentView.downloadPDFInBackground` gains a `pdfURLOverride: String?` parameter.
- `PDFDownloadService.downloadPDF(for:overrideURL:)` accepts the override and skips its arXiv/OpenAlex resolution when one is provided.

The DB save itself never sees the URL.

Flow when user pastes `https://openreview.net/forum?id=ABCD`:

```
AddByIdentifierView
  └─> MetadataResolver.resolveManualEntry(text)         // returns ManualEntryOutcome
        └─> MetadataFetcher.extractIdentifier(text)
              KnownPaperHost.classify(url)              // host + path-shape allowlist
              returns .paperURL(URL)                    // only if path matches a known shape
        └─> MetadataResolver.resolveIdentifierLocally(.paperURL(url), ...)
              └─> PaperURLResolver.resolve(url)
                    ├─ canonicalize URL (applied to Reference.url too — see §2.4)
                    ├─ rewritePDFURLToLanding(url)              // per-host regex
                    ├─ if host == thecvf:  CVF BibTeX adapter (uses BibTeXImporter)
                    │  else:               CitationMetaScraper.fetch
                    ├─ if citation_doi present:
                    │       MetadataFetcher.fetchFromDOI(doi)            // canonical
                    │       titleSimilarity(scraped.title, crossref.title) >= 0.80
                    │         else fall back to scraper-only Reference  (DOI-mismatch
                    │         safeguard; see §3 and §4)
                    │       MetadataResolution.mergeReference(
                    │         primary: crossrefRef, fallback: scraperRef) //  scraper
                    │                                                    //  fills
                    │                                                    //  gaps
                    └─ return Outcome(reference, scrapedPDFURL)
              produces VerifiedEnvelope; envelope shape unchanged
        └─> ManualEntryOutcome(result: .verified(envelope),
                               preferredPDFURL: scrapedPDFURL)
  └─> AddByIdentifierView gates the "Also download PDF" toggle on
      (ref.canDownloadPDF || preferredPDFURL != nil); on Import calls
      onSave(reference, downloadPDF, pdfURLOverride: preferredPDFURL)
  └─> ContentView.downloadPDFInBackground(reference, id, pdfURLOverride)
        └─> PDFDownloadService.downloadPDF(for: reference, overrideURL: pdfURLOverride)
              uses pdfURLOverride when non-nil (skips arXiv/OpenAlex resolution);
              else existing path.
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

`MetadataResolver.resolveIdentifierLocally` gains a `.paperURL` branch that delegates to `PaperURLResolver.resolve` and returns a `MetadataResolutionResult` *without* the URL. `MetadataResolver.resolveManualEntry` wraps the result + URL into `ManualEntryOutcome`.

### 2. Components

#### 2.1 `CitationMetaScraper`

One job: fetch a URL, parse `<meta name="citation_*">` tags, return a structured result. Stateless enum.

```swift
public struct CitationMetaResult: Sendable {
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
    /// Production entry: fetch + parse.
    public static func fetch(
        _ url: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15
    ) async throws -> CitationMetaResult

    /// Pure-string variant for unit tests — no network.
    public static func parse(
        html: String,
        baseURL: URL
    ) -> CitationMetaResult
}
```

Implementation notes:

- HTML parsing is a scanner over the `<head>` region. `<meta>` tags in `<head>` are flat across all target sites; no DOM parser needed.
- **No `<title>` fallback.** v2 included a `<title>` fallback when `citation_title` was absent. Removed in v3: none of the 10 hosts actually need it when functioning correctly, and accepting `<title>` was the gap that let paywall pages slip through (they preserve `<title>` but not `citation_*`). If `citation_title` is absent on a citation_*-based host, the scraper returns `title = nil` and the orchestrator rejects.
- `citation_author` collected in document order; `AuthorName.parseList` handles "Lastname, Firstname" format.
- `citation_publication_date` accepts `2024/06/12`, `2024-06-12`, or bare `2024`. Extract year. `citation_year` preferred if present.
- `citation_abstract` is rare; `og:description` more common but sometimes truncated. Prefer `citation_abstract` when both present. Both are scraper-derived; orchestrator can still gap-fill from CrossRef.
- **Relative `citation_pdf_url` resolution:** ACM and IEEE pages frequently serve a relative path. `parse(html:baseURL:)` resolves with `URL(string: relativePath, relativeTo: baseURL)?.absoluteString`. Only an absolute URL ever appears in `CitationMetaResult.pdfURL`.
- **Content-Type policy:** `fetch` accepts responses whose `Content-Type` starts with `text/html`, `application/xhtml+xml`, or is missing entirely. Rejects `application/pdf`, `image/*`, `application/octet-stream`, or anything else explicit. Missing-header acceptance is conservative — many CDN front-ends omit the header on cached HTML; we'd rather over-accept and let the parser produce an empty `CitationMetaResult` than over-reject on missing-but-valid responses.
- **Redirect tracking:** the final URL after redirects (from `HTTPURLResponse.url`) is the `baseURL` passed to `parse`, so relative `citation_pdf_url` values resolve against the page actually rendered, not the URL the user pasted.
- **Redirect-host check:** if `HTTPURLResponse.url`'s host is not on the `KnownPaperHost` allowlist (e.g. a redirect to a login page on `id.elsevier.com`), `fetch` throws an error that maps to the §4 "redirect to unrelated host" row.
- The scraper does **not** infer `referenceType` — that's the orchestrator's job (it knows the host).
- The scraper does **not** apply the "require citation_title + 1 more" gate — that's the orchestrator's job, since it knows whether the host is citation_*-based or BibTeX-based (CVF). See §2.3 step 6.
- **Retry contract.** `CitationMetaScraper.fetch` retries on `URLError.timedOut`, `URLError.networkConnectionLost`, HTTP 5xx, and HTTP 429 (3-second base backoff for 429, 1-second base for 5xx, exponential per attempt; matches the existing `MetadataFetcher.withRetry` policy). Does **not** retry on 4xx (except 429), DNS failures, content-type rejections, or HTML parse errors. The new code does not call `MetadataFetcher.withRetry` (it's private and bound to `FetchError`) — it inlines a small local retry helper matching this contract. ~30 lines duplicated; documented here so future maintainers know the contract is intentional, not accidental drift.

#### 2.2 `PaperURLResolver`

Stateless enum, no shared mutable state, no caching of its own (`MetadataFetcher.responseCache` caches completed CrossRef calls within its TTL).

```swift
public enum PaperURLResolver {
    public struct Outcome: Sendable {
        public let reference: Reference
        public let scrapedPDFURL: String?
    }

    public static func resolve(
        _ url: URL,
        session: URLSession = .shared
    ) async throws -> Outcome
}
```

Three responsibilities, broken out below.

#### 2.3 Host + path classification, rewrite, dispatch

**A. `KnownPaperHost` — host + path-shape allowlist**

```swift
internal enum KnownPaperHost: CaseIterable {
    case openReview, aclAnthology, cvfOpenAccess
    case neurIPS, pmlr, ieeeXplore, acmDL
    case nature, springer, scienceDirect

    static func classify(_ url: URL) -> KnownPaperHost?
}
```

`classify` returns non-nil **only when both host AND path match** a known shape. URLs like `https://link.springer.com/search?q=foo` correctly return nil and fall through. URL canonicalization (§2.4) is applied before matching.

Per-host path patterns:

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
| `link.springer.com` | `^/(article\|chapter\|book\|referenceworkentry)/.+$` | **n/a (no PDF→landing rewrite — see B)** |
| `www.sciencedirect.com` | `^/science/article/(pii\|abs/pii)/.+$` | `^/science/article/.+/pdfft$` |

If the URL host is on the list but the path matches neither landing nor PDF regex (e.g. `link.springer.com/search?q=foo`, IEEE journal homepages, ACM table-of-contents pages), `classify` returns nil. The URL falls through `extractIdentifier` to existing extraction.

**B. PDF-URL → landing-page rewrite**

| Input PDF URL | Rewritten landing URL | Notes |
|---|---|---|
| `openreview.net/pdf?id=ABCD` | `openreview.net/forum?id=ABCD` | Query string preserved verbatim |
| `aclanthology.org/2024.acl-long.123.pdf` | `aclanthology.org/2024.acl-long.123/` | Append slash, strip `.pdf` |
| `openaccess.thecvf.com/.../papers/Foo.pdf` | `openaccess.thecvf.com/.../html/Foo.html` | Path-segment swap |
| `papers.nips.cc/paper/2024/file/abc.pdf` | `papers.nips.cc/paper/2024/hash/abc.html` | Segment + ext swap |
| `proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Conference.pdf` | `proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Conference.html` | **Regex: `(.+)-Paper(.*)\.pdf` → `\1-Abstract\2.html`** — covers track variants like `Paper-Datasets_and_Benchmarks_Track` |
| `proceedings.mlr.press/v200/foo23a/foo23a.pdf` | `proceedings.mlr.press/v200/foo23a.html` | Strip duplicate segment + ext swap |
| `dl.acm.org/doi/pdf/10.1145/foo` | `dl.acm.org/doi/10.1145/foo` | Drop `/pdf` segment |
| `nature.com/articles/foo.pdf` | `nature.com/articles/foo` | Strip `.pdf` |
| `link.springer.com/content/pdf/10.1007/foo.pdf` | **(no rewrite — see below)** | |
| `www.sciencedirect.com/science/article/pii/SXXXX/pdfft` | `www.sciencedirect.com/science/article/pii/SXXXX` | Strip `/pdfft` |

**Why no Springer PDF→landing rewrite:** Springer URLs differ by content type (`/article/`, `/chapter/`, `/book/`, `/referenceworkentry/`). The PDF URL shape `/content/pdf/<doi>.pdf` doesn't tell us which content type the DOI resolves to. A blanket `/content/pdf/<doi>.pdf` → `/article/<doi>` rewrite turns chapter and book PDFs into 404 article URLs. Until we have DOI-content-type resolution (out of scope for v3), Springer PDF URLs are not auto-rewritten: they fall through `KnownPaperHost.classify` (no Springer PDF path regex) and the user receives the §4 fallthrough behavior. They can paste the landing URL (`/chapter/...`, `/article/...`, etc.) directly.

**C. Dispatch and post-processing**

Algorithm in `PaperURLResolver.resolve`:

1. Apply URL canonicalization (§2.4).
2. Classify host. If `nil`, throw (defensive — `extractIdentifier` already classified, so this is a path that should never trigger).
3. Rewrite PDF URL to landing URL if a rewrite rule applies; otherwise pass through.
4. If host == `.cvfOpenAccess`, run the CVF BibTeX adapter (§3 Case C). Otherwise, run `CitationMetaScraper.fetch`.
5. Build a draft `Reference` from the scraper / BibTeX result. `referenceType` chosen from host:
   - `.cvfOpenAccess`, `.neurIPS`, `.pmlr` → `.conferencePaper`.
   - `.openReview` → `.conferencePaper`.
   - `.aclAnthology` → `.conferencePaper` if `citation_conference_title` present, else `.journalArticle`.
   - `.ieeeXplore`, `.acmDL`, `.nature`, `.springer`, `.scienceDirect` → `.journalArticle` if `citation_journal_title` present, else `.conferencePaper` if `citation_conference_title`, else `.journalArticle` default.
6. **Strong evidence gate** (replaces v2's weak "≥ 2 fields" gate). For citation_*-based hosts (everything except CVF), require **`citation_title` to be present AND at least one of `citation_author`, `citation_doi`, `citation_publication_date` / `citation_year`, `citation_journal_title`, or `citation_conference_title`**. If not, reject (§4 "Page did not expose paper metadata"). This is the v3 paywall safeguard: login interstitials and access-denied pages typically preserve the `<title>` tag but not the full `citation_*` set. CVF (BibTeX path) is exempt — its strong evidence gate is `BibTeXImporter.parse` returning a non-empty Reference.
7. If `result.doi` is non-nil, call `MetadataFetcher.fetchFromDOI(doi)`.
   - **On success**, compute `MetadataResolution.titleSimilarity(scraped.title, crossref.title)`. If **≥ 0.80**, use CrossRef as primary and scraper as fallback via `MetadataResolution.mergeReference(primary: crossref, fallback: scraper)`. If < 0.80, log via `resolverTrace("paperURL: DOI-title mismatch …")` and fall back to scraper-only. The 0.80 threshold matches the existing `resolveByTitle` and `refreshWithOpenAlexTitleSearch` paths (`MetadataResolver.swift:302, 344`); it specifically guards against the chapter-vs-book DOI scenario (parent book titled "Foundations of Machine Learning" vs chapter titled "Foundations of Deep Learning" share ~0.7 similarity but are different works).
   - **On failure** (network / 5xx / parse), log and use scraper-only Reference. CrossRef outages remain non-fatal.
   - **No-author safeguard.** After the merge (or after a CrossRef failure / title-similarity fall-back), if the resulting `Reference.authors` is empty, reject with `.candidate` rather than allow auto-verify. The existing `MetadataVerifier.verify` (`MetadataVerifier.swift:10-17`) auto-verifies the direct-identifier path on title + identifier alone — authors are NOT required. Without this safeguard, a paper page that exposes `citation_title + citation_doi` but no `citation_author` (older IEEE pages have been observed in this shape) plus a CrossRef failure would silently produce a `.verified` Reference with no authors. Return a `.candidate` envelope so the user reviews the result rather than the resolver auto-verifying it. (CVF path is not affected: `BibTeXImporter.parse` requires the `author = {…}` field for `@inproceedings` blocks in practice; an author-less BibTeX block would already fail the §4 "Reference has empty title" check or produce an empty author list which this same safeguard catches.)
8. `Reference.url` is set to the **canonical landing URL** (post-rewrite, post-canonicalization). v2 stored the user's original-case input here; v3 reverses that decision because `findDuplicateReferenceID` (`AppDatabase.swift:2001`) does exact-string URL comparison — two paper URLs differing only in scheme case, host case, `www.` prefix, fragment, or default port would otherwise become separate references. The canonical form keeps duplicate detection working.
9. `Reference.metadataSource` is set to one of:
   - `.cvfOpenAccess` (NEW) — when the CVF BibTeX adapter produced the Reference.
   - `.publisherCitationMeta` (NEW) — for every other case (citation_* scraper produced the Reference, regardless of whether DOI re-fetch happened).
   - CrossRef-fetched references continue to be labeled `.translationServer` (current behavior preserved). This spec does **not** add a `.crossref` case.
10. Return `Outcome(reference, scrapedPDFURL: result.pdfURL)`. `scrapedPDFURL` is always an absolute URL (relative paths resolved in §2.1).

#### 2.4 URL canonicalization rules

A single function `PaperURLResolver.canonicalize(_ url: URL) -> URL`. **Applied uniformly** for classification, host matching, and the final form stored on `Reference.url`. The canonical form is also what the user sees when opening "original URL" affordances — small visual change (e.g. uppercase `HTTP` becomes `http`) but no semantic difference.

Rules:

| Aspect | Rule | Notes |
|---|---|---|
| Scheme | Lowercase. Reject if not `http` or `https`. | RFC 3986 §3.1. |
| Host | Lowercase. | URL hosts are case-insensitive. |
| `www.` prefix | Strip. | Canonical: `nature.com`, not `www.nature.com`. |
| Default ports | Strip `:80` for http, `:443` for https. | None of our publishers use non-standard ports. |
| Fragment | Strip. | `#section-2` is client-side only. |
| Trailing slash on path | **Preserve.** | Path regex must accept both forms. |
| Path case | Preserve. | Paths are case-sensitive (RFC 3986 §3.3). |
| Query parameter order | Preserve. | OpenReview routing depends on `?id=…`. |
| Query parameter case | Preserve. | Same rationale. |
| Percent-encoding | Preserve. | Don't decode-then-re-encode. |
| http vs https | If both work for a publisher, store as `https`. The fetch uses whatever the canonical scheme is (we don't auto-upgrade — publishers' own redirects handle that). | Practical effect: all current target sites support `https`; `http` URLs get upgraded by the publisher and we redirect-follow. |

Edge cases:
- **`URL(string:)` rejects malformed percent-encoding.** Already rejected upstream as "not a valid URL".
- **Internationalized domain names (IDN).** Out of scope. None of our target publishers use IDN hosts.
- **URL with embedded credentials (`user:pass@host`).** Reject — `classify` returns nil.

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

#### 2.6 `MetadataResolver.resolveIdentifierLocally` and `resolveManualEntry` — extended

`resolveIdentifierLocally`'s signature changes from `async -> MetadataResolutionResult` to `async -> (MetadataResolutionResult, scrapedPDFURL: String?)`. This is the explicit propagation channel — no actor-isolated side state, no implicit globals. All existing branches (`.doi`, `.pmid`, `.arxiv`, `.isbn`, `.pmcid`) return `(result, nil)`. The new `.paperURL` branch returns `(result, outcome.scrapedPDFURL)`.

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
        case .doi(let value):    reference = try await MetadataFetcher.fetchFromDOI(value)
        case .pmid(let value):   reference = try await MetadataFetcher.fetchFromPMID(value)
        case .arxiv(let value):  reference = try await MetadataFetcher.fetchFromArXiv(value)
        case .isbn(let value):   reference = try await MetadataFetcher.fetchFromISBN(value)
        case .pmcid(let value):  reference = try await MetadataFetcher.fetchFromPMCID(value)
        case .paperURL(let url):
            let outcome = try await PaperURLResolver.resolve(url)
            reference = outcome.reference
            scrapedPDFURL = outcome.scrapedPDFURL
        }
        // ... existing evidence + verification logic unchanged ...
        let result = verifyFetchedRecord(...)
        // Force scrapedPDFURL to nil for any non-verified outcome — preferredPDFURL
        // is defined as "populated only on .verified" (§1, ManualEntryOutcome doc
        // comment). Candidate (no-author safeguard), blocked, rejected, and seedOnly
        // outcomes do not carry a URL forward; queued-review paths drop it
        // explicitly (§4 "queued path drops scrapedPDFURL").
        let effectiveScrapedPDFURL: String? = {
            if case .verified = result { return scrapedPDFURL }
            return nil
        }()
        return (result, effectiveScrapedPDFURL)
    } catch {
        return (.rejected(...), nil)
    }
}
```

This is the **only** function whose signature changes. `resolveManualEntry`, `resolveSeed`, `refreshReference`, etc. continue to return `MetadataResolutionResult` (or its existing variants); they just consume the tuple, discard `scrapedPDFURL` if they don't need it, and use the `.0` result.

`resolveManualEntry` collects the tuple and wraps it:

```swift
public func resolveManualEntry(_ text: String) async -> ManualEntryOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // ... existing identifier-extraction logic ...
    let (result, scrapedPDFURL) = await resolveIdentifierLocally(...)
    return ManualEntryOutcome(result: result, preferredPDFURL: scrapedPDFURL)
}
```

Callers of `resolveManualEntry` (verified by `rg`: `AddByIdentifierView.swift:200`, `BatchImportView.swift:230`, `BatchImportView.swift:252`, and the retry path at `MetadataResolver.swift:188`) update to read `.result` from the wrapper. `BatchImportView` ignores `preferredPDFURL` (batch import doesn't auto-download URL-derived PDFs — see §4 "queued path"); only `AddByIdentifierView` uses it. `MetadataResolver.retryIntake` ignores it too (retry path doesn't carry a URL forward — see §4 "queued path drops scrapedPDFURL").

`MetadataResolutionResult` itself is unchanged. All 26 `.verified(` pattern-match sites continue to work without edit.

#### 2.7 `Reference.canDownloadPDF` and `AddByIdentifierView` toggle gating

`Reference.canDownloadPDF` (`Reference.swift:381`) is **not modified**. It continues to return `true` only for DOI or `arxiv.org/abs/`-bearing references, reflecting "does this reference, by itself, have enough data to find a PDF later?"

`AddByIdentifierView` gates the toggle on the combined condition:

```swift
Toggle(...)
    .disabled(!ref.canDownloadPDF && preferredPDFURL == nil)
```

For OpenReview/CVF/PMLR papers without a DOI, `canDownloadPDF` is false but `preferredPDFURL` is non-nil → toggle enabled.

On Import:

```swift
onSave(ref, downloadPDFOnImport && (ref.canDownloadPDF || preferredPDFURL != nil),
       pdfURLOverride: preferredPDFURL)
```

#### 2.8 `PDFDownloadService.downloadPDF` — URL override

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

`ContentView.downloadPDFInBackground` adds the `pdfURLOverride: String?` parameter and forwards it to `downloadPDF`.

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
          pdfURL: "https://openreview.net/pdf?id=ABCD" }   // absolute
      strong evidence gate passes (citation_title + citation_author + ...)
      doi == nil -> build Reference directly
        referenceType = .conferencePaper
        metadataSource = .publisherCitationMeta
        url = "https://openreview.net/forum?id=ABCD"      // canonical
 4. Outcome(reference, scrapedPDFURL: "https://openreview.net/pdf?id=ABCD")
 5. MetadataResolver returns ManualEntryOutcome(.verified(env),
                                                preferredPDFURL: "<pdf url>")
 6. AddByIdentifierView: ref.canDownloadPDF == false BUT preferredPDFURL != nil
    -> toggle enabled, user clicks Import
 7. onSave(reference, downloadPDF: true, pdfURLOverride: "<pdf url>")
 8. ContentView.downloadPDFInBackground(reference, id, pdfURLOverride: "<pdf url>")
 9. PDFDownloadService.downloadPDF(for: reference, overrideURL: "<pdf url>")
    downloads directly, hashes, stores via PDFAssetCache
```

**Case B — ACL Anthology direct-PDF URL** (DOI present):

```
input: https://aclanthology.org/2024.acl-long.123.pdf
 1. KnownPaperHost.classify -> .aclAnthology (PDF path matched)
 2. extractIdentifier -> .paperURL(URL)
 3. PaperURLResolver.resolve
      canonicalize: no visible change
      rewritePDFURLToLanding -> https://aclanthology.org/2024.acl-long.123/
      CitationMetaScraper.fetch (on landing)
        { ..., doi: "10.18653/v1/2024.acl-long.123",
          pdfURL: "https://aclanthology.org/2024.acl-long.123.pdf" }
      strong evidence gate passes
      doi present -> MetadataFetcher.fetchFromDOI("10.18653/v1/...")
        titleSimilarity(scraped.title, crossref.title) >= 0.80 -> use CrossRef
        MetadataResolution.mergeReference(primary: crossrefRef, fallback: scraperRef)
        reference.url = "https://aclanthology.org/2024.acl-long.123/" (canonical)
        reference.metadataSource = .publisherCitationMeta
        scrapedPDFURL preserved
 4..9 same as Case A
```

**Case C — CVF Open Access** (no citation_* meta):

```
input: https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html
 1. KnownPaperHost.classify -> .cvfOpenAccess (landing path matched)
 2. extractIdentifier -> .paperURL(URL)
 3. PaperURLResolver.resolve
      canonicalize: no visible change
      host == .cvfOpenAccess -> CVF BibTeX adapter:
        - GET landing page using the SAME helper as CitationMetaScraper.fetch
          (content-type + redirect-host checks inherited verbatim; both adapters
          call into a small internal `fetchHTML(url:session:)` helper defined
          inside PaperURLResolver.swift, ~25 lines, used by exactly these two
          callers — citation_* scraper and CVF adapter)
        - Extract <pre>...</pre> contents via regex on response body
        - Parse with BibTeXImporter.parse -> [Reference]; take first.
          If array empty or first.title is blank, throw (§4 row).
        - Synthesize pdfURL:
            ".../html/Foo_paper.html" -> ".../papers/Foo_paper.pdf"
      Reference{ referenceType: .conferencePaper,
                 journal: "Proceedings of the IEEE/CVF Conference...",
                 eventTitle: same (set by BibTeXImporter for @inproceedings),
                 url: "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html",
                 metadataSource: .cvfOpenAccess }
 4..9 same as Case A
```

### 4. Error handling

Same `MetadataResolutionResult` machinery; no new envelope types.

| Condition | Result | User-facing message |
|---|---|---|
| URL host not in allowlist | falls through `extractIdentifier`; existing title-search path applies | (unchanged) |
| URL host in allowlist but path does not match a known shape (Springer search pages, IEEE journal homepages, Springer PDF URLs) | falls through `extractIdentifier`; existing identifier extraction applies | (unchanged) |
| URL has embedded credentials (`user:pass@host`) | `KnownPaperHost.classify` returns nil → falls through | (unchanged) |
| Allowlisted host, GET returns 4xx/5xx | `.rejected(insufficientEvidence)` | "Could not load <host> page (HTTP <code>). Check the URL or try a DOI." |
| Response `Content-Type` is explicit and not `text/html` / `application/xhtml+xml` (typically `application/pdf` or binary) | `.rejected(insufficientEvidence)` | "Expected an HTML page; the URL returned <type>. Paste the abstract/landing page URL instead of the PDF." |
| HTTP redirect to a host **not** on the allowlist | `.rejected(insufficientEvidence)` | "Page redirected to <new-host>, which may require login. Try the canonical landing URL." |
| Allowlisted citation_*-based host + path, GET succeeds, scraper extracts no `citation_title` OR no other `citation_*` tag | `.rejected(insufficientEvidence)` | "Page did not expose paper metadata. Try pasting the DOI or paper title." |
| Scraper produces DOI, CrossRef call fails (network / 5xx / parse) | **fall through** — return scraper-only Reference; log via `resolverTrace`. Not an error. | (no error surfaced) |
| Scraper produces DOI, CrossRef succeeds, but `titleSimilarity(scraped, crossref) < 0.80` | **fall through** — return scraper-only Reference; log warning. DOI preserved on Reference. | (no error surfaced; protects against chapter-vs-book mismatch) |
| Final merged `Reference.authors` is empty (scraper had no `citation_author` and CrossRef either failed or also returned no authors) | `.candidate` — `CandidateEnvelope` with `candidates = [MetadataCandidate(from: scrapedReference)]` (single-element list built from the scraped data), `message = "Found a paper, but no authors are listed…"`. User reviews via existing candidate-confirmation UI before the result becomes `.verified`. | "Found a paper, but no authors are listed on the page or in CrossRef. Review before importing." |
| Network timeout (15s, matches existing `MetadataFetcher` timeout) | `.rejected(insufficientEvidence)` | `error.localizedDescription` |
| CVF page returns 200 but no `<pre>` BibTeX block matches | `.rejected(insufficientEvidence)` | "Could not find BibTeX on this CVF page. The page format may have changed." |
| BibTeX block found, `BibTeXImporter.parse` returns empty array or first Reference has blank title | `.rejected(insufficientEvidence)` | "Found BibTeX but it did not contain usable fields." |
| PDF-URL rewrite produces a URL we then fail to fetch (404 on rewritten landing URL) | `.rejected(insufficientEvidence)` | "Loaded PDF URL but no matching landing page. Try the abstract page URL." |
| Malformed URL string (`URL(string:) == nil`) | falls through `extractIdentifier`; existing title-search applies | (unchanged) |

**Three policies encoded above:**

- **CrossRef-fail is non-fatal.** A scraped Reference with DOI degrades to scraper-only when CrossRef hiccups.
- **Title-similarity-fail is non-fatal but degraded.** When CrossRef returns a paper with a title that doesn't match the scraped title (`titleSimilarity < 0.80`), trust the scraper's `Reference` and log the mismatch. Protects against the chapter-vs-book DOI scenario.
- **No-author safeguard.** Empty `Reference.authors` after merge degrades the result from `.verified` to `.candidate`. The existing `MetadataVerifier.verify` auto-verify path requires only title + identifier (`MetadataVerifier.swift:10-17`); without this safeguard, an author-less scraper Reference paired with a CrossRef failure would silently auto-verify. The candidate envelope routes the result through the existing user-review UI.
- **No fallback to title-search.** Failed paper URLs don't silently re-query OpenAlex by the page `<title>`. Silent re-routing of pasted URLs is confusing UX.

**Queued-review path: PDF URL is dropped.** When `PaperURLResolver` produces a `.candidate` / `.blocked` / `.seedOnly` / `.rejected` result (i.e. anything not `.verified`), the `scrapedPDFURL` is *not* persisted into the intake queue. Pending intakes currently have only `pdfPath` for local-file handoff (`AppDatabase.swift:1741, 1880`); adding a URL column would require a migration, which is out of scope. The user retains `Reference.url` (the landing page) and can re-trigger PDF download by promoting the queued intake to verified and pasting the PDF URL directly if desired. In practice, paper URLs almost always resolve to `.verified` results when the page exposes citation_* tags correctly; queued results are the failure-mode path.

**Concurrency note.** `PaperURLResolver` is a stateless enum and holds no caches. The existing `MetadataFetcher.responseCache` is a plain `NSCache` (`MetadataFetcher.swift:22-45`) that caches *completed* results only — **it does not coalesce in-flight requests**. Two concurrent paste-and-import operations for the same URL therefore each perform an independent HTML fetch and (if a DOI is found) an independent CrossRef call. For a manual paste box this is acceptable: double-paste is rare, and the worst case is one extra network roundtrip. We are explicitly **not** adding in-flight coalescing in v3. If real-world usage shows duplicate-paste being a problem, a follow-up can add a `[URL: Task<Outcome, Error>]` in-flight map keyed on the canonical URL.

### 5. Testing

All new tests live in `RubienCoreTests` (fastest target; no SwiftUI dep). No new test target.

**Pure unit tests (no network)**

1. **`KnownPaperHostClassifyTests.swift`** — host + path classification table tests.
   - Per host: ≥ 3 positive landing URLs, ≥ 1 positive PDF URL (except Springer, which has no PDF path regex), ≥ 2 negative URLs (host matches, path doesn't).
   - **Springer-specific negatives:** `link.springer.com/content/pdf/10.1007/foo.pdf` → nil (no PDF rewrite; falls through), `link.springer.com/search?q=foo` → nil, `link.springer.com/journal/123` → nil.
   - Negative table: URLs from random hosts → nil.
   - Canonicalization edge cases as a separate test method: `www.` prefix, mixed-case host, `HTTP` vs `http`, fragment present, trailing slash variants, default port, embedded credentials → rejected.
   - Canonical-URL invariant test: feeding two URLs that should canonicalize to the same form (e.g. `HTTP://WWW.NATURE.COM/articles/X` and `https://nature.com/articles/X`) produces identical `Reference.url` strings.

2. **`PaperURLRewriteTests.swift`** — PDF → landing rewrite table tests, per host.
   - **NeurIPS regex regression cases:** main-track (`abc-Paper-Conference.pdf` → `abc-Abstract-Conference.html`), datasets track (`abc-Paper-Datasets_and_Benchmarks_Track.pdf` → `abc-Abstract-Datasets_and_Benchmarks_Track.html`), and the legacy `papers.nips.cc/paper/<year>/file/<file>.pdf` shape.
   - **Springer regression:** any `link.springer.com/content/pdf/...` URL is not classified as a paper URL (returns nil from `classify`).

3. **`CitationMetaScraperParseTests.swift`** — `parse(html:baseURL:)` over captured fixtures.
   - Fixtures in `Tests/RubienCoreTests/Fixtures/CitationMeta/`:
     - `openreview-forum.html`, `aclanthology-paper.html`, `neurips-proceedings.html`, `pmlr-paper.html`, `ieee-xplore.html`, `nature-article.html`, `springer-chapter.html`, `acm-dl.html`, `sciencedirect-article.html`.
   - Each fixture header-commented with source URL and capture date.
   - Each test: feed fixture HTML, assert every populated field.
   - **Relative `citation_pdf_url` test:** ACM/IEEE fixtures contain relative PDF URLs; assert output is the absolute resolved form.
   - **Missing `citation_pdf_url` test:** fixture with no PDF tag; assert `pdfURL == nil`.
   - **No `citation_title` test:** scraper returns `title == nil`. Orchestrator (separate test in §5/5) rejects with the strong-evidence-gate error.
   - **`<title>`-only HTML test:** confirm scraper does NOT fall back to `<title>` (regression against v2 behavior).
   - **Paywall fixture:** `paywall-login-page.html` (real captured login interstitial) — scraper extracts `title=nil` because `citation_title` is absent → orchestrator rejects.
   - Negative fixtures: `no-citation-meta.html` (empty result), `malformed-meta.html` (doesn't crash; partial result OK).

4. **`BibTeXImporterCVFTests.swift`** — closes the gap that `BibTeXImporter.parse(_:)` has no direct unit tests.
   - 6–10 real CVF BibTeX blocks (CVPR/ICCV/WACV/ECCV); assert field-by-field.
   - Standard `@InProceedings`, multi-author (5+), title with LaTeX braces, `month = june`, block followed by HTML noise, block without `doi`, multi-line title.

**Orchestrator tests with injected transport**

5. **`PaperURLResolverTests.swift`** — `resolve(url, session:)` with a stub `URLSession` (custom `URLProtocol` registered for a `URLSessionConfiguration`).
   - OpenReview landing → fixture HTML → expect Outcome with `.conferencePaper` Reference, `metadataSource == .publisherCitationMeta`, scrapedPDFURL absolute.
   - ACL PDF URL → rewrite → fixture HTML with DOI → CrossRef stub returns matching JSON → expect merged Reference (CrossRef primary).
   - ACL PDF URL → CrossRef stub returns 503 → expect scraper-only Reference (CrossRef-fail non-fatal).
   - **Chapter-vs-book DOI mismatch test:** ACL fixture asserts scraper title; CrossRef stub returns a different-but-related work (titleSimilarity ~0.7, below 0.80). Expect scraper-only Reference; log warning observed via injected logger.
   - **Exact-similar-threshold test:** scraper title vs CrossRef title at exactly 0.80 → CrossRef primary. At 0.79 → scraper-only.
   - CVF landing → fixture HTML with `<pre>` BibTeX → expect Reference from BibTeXImporter, pdfURL synthesized.
   - PDF URL rewrite → rewritten landing URL returns 404 → expect `.rejected`.
   - HTML content-type check → response with `application/pdf` → expect `.rejected`.
   - **XHTML / missing Content-Type:** response with `application/xhtml+xml` → accepted. Response with no Content-Type header → accepted.
   - Redirect-to-unrelated-host → expect `.rejected`.
   - **Strong evidence gate:** fixture with only `citation_title` (no other citation_* tags) → expect `.rejected` (paywall-style).
   - **Canonical URL on Reference.url:** input `HTTP://WWW.NATURE.COM/articles/Foo` → resulting Reference.url == `https://nature.com/articles/Foo`.
   - **Retry behavior (§2.1 contract):** stub URLSession returns HTTP 503 on first attempt, 200 (with valid HTML) on second → expect success after retry. HTTP 429 → retry with 3-second base backoff (assert ≥3s delay via clock injection or sleep mock). `URLError.timedOut` → retry. HTTP 404 → no retry, fail immediately. HTTP 500-599 with maxAttempts exhausted → `.rejected`.

**Extraction-level tests**

6. **`PaperURLExtractionTests.swift`** — `MetadataFetcher.extractIdentifier` cases.
   - `https://openreview.net/forum?id=ABCD` → `.paperURL`.
   - `https://openreview.net/pdf?id=ABCD` → `.paperURL`.
   - `https://aclanthology.org/2024.acl-long.123/` → `.paperURL`.
   - `https://www.nature.com/articles/s41586-024-12345-6` → `.paperURL`.
   - `https://link.springer.com/article/10.1007/s11042-024-12345-6` → `.paperURL`.
   - `https://link.springer.com/chapter/10.1007/978-3-540-24777-7_1` → `.paperURL`.
   - **`https://link.springer.com/content/pdf/10.1007/foo.pdf` → `nil`** (no Springer PDF route).
   - `https://link.springer.com/search?q=neural` → `nil`.
   - `https://example-blog.com/post/hello` → `nil`.
   - `10.1234/abc` (bare DOI) → existing `.doi(...)` unchanged.
   - Canonicalization regression: `HTTP://WWW.NATURE.COM/articles/...` → `.paperURL` after canonicalization.

**Integration tests with stubbed network**

7. **`MetadataResolverPaperURLTests.swift`** — end-to-end through `MetadataResolver.resolveManualEntry` returning `ManualEntryOutcome`.
   - One success test per adapter family (citation_*, citation_*+DOI, CVF BibTeX) — verify `.verified` result + `preferredPDFURL` populated on the outcome.
   - One failure-path test per §4 error row, including the new **no-author-safeguard** row: stubbed scraper returns Reference with empty authors + CrossRef stub returns 503 → expect `.candidate` (NOT `.verified`).
   - `Reference.url` is the canonical landing URL.
   - **Post-merge URL overwrite test:** ACL fixture with DOI; CrossRef stub returns a Reference whose `url` field is `https://doi.org/10.X/Y` (CrossRef's `resource.primary.URL`). After `mergeReference`, assert the final `Reference.url` is the canonical landing URL, not the doi.org redirect.
   - **`BatchImportView` callers ignore `preferredPDFURL`:** integration test verifies that batch import doesn't auto-download from URL-derived references.

7a. **`AddByIdentifierPaperURLUITests.swift`** — focused tests on the UI gating logic without snapshots.
   - With `preferredPDFURL == nil` AND `ref.canDownloadPDF == false` → toggle disabled.
   - With `preferredPDFURL == nil` AND `ref.canDownloadPDF == true` (DOI present) → toggle enabled; onSave called with `pdfURLOverride: nil`.
   - With `preferredPDFURL != nil` AND `ref.canDownloadPDF == false` (OpenReview-style) → toggle enabled; onSave called with `pdfURLOverride: <url>`.
   - With `preferredPDFURL != nil` AND user unchecks toggle → onSave called with `downloadPDF: false, pdfURLOverride: <url>` (URL still threaded; download skipped).
   - Implementation note: the view's `downloadPDFOnImport` state and `preferredPDFURL` consumption can be tested either via SwiftUI `ViewInspector`-style integration or by extracting a small `AddByIdentifierViewModel` struct that holds the gating logic. Decision deferred to implementation; spec requires only that the gating combinations above are covered.

8. **`ReferenceDuplicateCanonicalURLTests.swift`** — regression: inserting two paper-URL References with input URLs that should canonicalize identically (varying case / `www.` / fragment) results in `findDuplicateReferenceID` finding the existing row and returning a duplicate match.

**Live smoke tests (gated)**

9. **`PaperURLLiveSmokeTests.swift`** — opt-in via env var `RUBIEN_LIVE_TESTS=1`. Skipped in CI.
   - For each of the 10 hosts: fetch a known stable URL, assert parser produces at least `{ title, authors, year }`. Doesn't assert exact values; just smokes that meta tags are still present.
   - Companion script `Scripts/refresh-citation-fixtures.sh` re-captures `<head>` from each smoke URL into the fixture directory.

**Tests we are NOT writing**

- CLI integration tests — `rubien-cli add` already exercises `resolveManualEntry`; if unit tests pass, CLI works.
- SwiftUI snapshot tests on `AddByIdentifierView` — toggle-gating change is structural, not visual.
- `RubienSyncTests` — no `Reference` model field changes, no `CKRecord` field changes.

**Fixture rot mitigation**

- Each fixture file has a header noting source URL and capture date.
- `Tests/RubienCoreTests/Fixtures/CitationMeta/FIXTURE-NOTES.md` lists every site, expected meta-tag set, and refresh procedure.

## Implementation order

Each step is a self-contained commit that builds and passes its own tests. v5 bundles v4's steps 3 + 4 to resolve a real ordering dependency: `CitationMetaScraper.fetch`'s redirect-host check references `KnownPaperHost` (defined in `PaperURLResolver.swift`), and both adapters share the internal `fetchHTML(url:session:)` helper also defined in `PaperURLResolver.swift`. Shipping `CitationMetaScraper.swift` alone in a prior step would not compile.

1. **Add `MetadataSource.cvfOpenAccess`** and **`.publisherCitationMeta`**. Two enum case additions, zero behavior change. Lands first because subsequent steps reference them. Verified forward-compatible decode behavior at `ReferenceRecord.swift:232`. No exhaustive switches over `MetadataSource` exist in the current codebase (verified by `rg "switch.*MetadataSource|case \.translationServer"`), so adding cases doesn't break any caller.
2. **`BibTeXImporterCVFTests.swift`** — direct unit tests on existing importer with CVF fixtures. Locks in BibTeX behavior before we depend on it.
3. **`CitationMetaScraper.swift` + `PaperURLResolver.swift` together, in one commit.** This is the largest step; both files ship together because of the cross-dependency described above (`KnownPaperHost`, `fetchHTML`). Includes:
   - `CitationMetaScraper.swift` with `fetch(url:session:)` (calling shared `fetchHTML`), `parse(html:baseURL:)`, the inlined ~30-line retry helper matching §2.1's explicit contract (`URLError.timedOut`, `URLError.networkConnectionLost`, HTTP 5xx, HTTP 429).
   - `PaperURLResolver.swift` with `KnownPaperHost.classify` (host + path), URL canonicalization, PDF→landing rewrite (incl. NeurIPS regex; no Springer PDF rewrite), dispatch, strong evidence gate, 0.80 title-similarity threshold, **no-author safeguard returning `.candidate`**, and the small internal `fetchHTML(url:session:)` helper used by both adapters (content-type + redirect-host checks; CVF adapter inherits the same retry helper as `CitationMetaScraper.fetch` by calling `fetchHTML` through the same retry wrapper).
   - Tests: `CitationMetaScraperParseTests.swift`, `KnownPaperHostClassifyTests.swift`, `PaperURLRewriteTests.swift`, `PaperURLResolverTests.swift`, plus the fixtures directory.
4. **Extend `MetadataFetcher.Identifier` + `extractIdentifier` + `MetadataResolver.resolveIdentifierLocally` in one commit** (was steps 4+5 in v3; bundled because the enum case addition alone breaks switch exhaustiveness at `MetadataFetcher.fetch:1093` and `resolveIdentifierLocally`). This step:
   - Adds `case paperURL(URL)` to `Identifier`.
   - Adds the `.paperURL` arm to `MetadataFetcher.fetch(identifier:)` — throws `.invalidURL` (the function isn't called for paper URLs since `resolveIdentifierLocally` handles them directly, but the switch arm exists for exhaustiveness).
   - Changes `resolveIdentifierLocally`'s signature from `async -> MetadataResolutionResult` to `async -> (MetadataResolutionResult, scrapedPDFURL: String?)`. Five existing branches return `(result, nil)`; new `.paperURL` branch returns `(result, outcome.scrapedPDFURL)`. Non-verified outcomes force `scrapedPDFURL = nil` per §2.6.
   - Updates callers of `resolveIdentifierLocally` inside `MetadataResolver` (a single file) to consume the tuple and discard `scrapedPDFURL` if they don't use it.
   - Includes `PaperURLExtractionTests.swift`.
5. **Introduce `ManualEntryOutcome` wrapper** on `MetadataResolver.resolveManualEntry` (signature change at one public entry point). Update the 4 call sites (`AddByIdentifierView`, `BatchImportView` ×2, `MetadataResolver.retryIntake`) to read `.result`. `MetadataResolutionResult` enum shape unchanged. With `MetadataResolverPaperURLTests.swift`.
6. **UI/background plumbing for PDF override:** `AddByIdentifierView.onSave` signature change, `ContentView.downloadPDFInBackground` signature change, `PDFDownloadService.downloadPDF(overrideURL:)`. Placeholder caption updated to "Supports DOI · arXiv · PMID · PMCID · ISBN · paper URL · title". With `AddByIdentifierPaperURLUITests.swift`.
7. **`ReferenceDuplicateCanonicalURLTests.swift`** + **gated live smoke tests + fixture refresh script.**

## Out-of-scope follow-ups (file separately)

Surfaced during this design but explicitly **not** addressed here:

- **`BibTeXImporter.swift:113`** — arXiv `@misc{}` entries import as `.webpage`. Should detect `archivePrefix = {arXiv}` / `eprint = {…}` / arxiv.org URL and return `.journalArticle` (or `.preprint` if added). Pre-existing bug.
- **Bulk BibTeX import has no "Also download PDF" affordance.** Pre-existing UX gap.
- **Backfilling `MetadataSource.crossref` for existing CrossRef-fetched references.** Today these are labeled `.translationServer`. A follow-up could add the case and migrate.
- **Springer PDF→landing rewrite via DOI content-type resolution.** Needs a DOI HEAD request to determine `/article/` vs `/chapter/` vs `/book/`; deferred to keep v3 scope tight.
- **In-flight coalescing for concurrent duplicate paste.** Current behavior accepts one extra network call per duplicate paste. Add a `[URL: Task]` in-flight map if real usage shows this matters.
- **Shared HTTP client extraction (`RubienHTTPClient`).** Two new callers (`CitationMetaScraper`, the CVF BibTeX adapter inside `PaperURLResolver`) inline ~10 lines of User-Agent + retry duplication. If a fourth caller appears (or `PDFDownloadService` gets reworked), extracting a shared client becomes worthwhile.
- **Canonical-URL duplicate detection misses legacy non-canonical rows.** `findDuplicateReferenceID` (`AppDatabase.swift:2001`) does exact-string URL comparison. References inserted **before** this feature lands with non-canonical URLs (e.g. `https://www.OPENREVIEW.net/forum?id=X` with uppercase host) will not match newly pasted canonical URLs (`https://openreview.net/forum?id=X`). DOI-bearing legacy references are unaffected (DOI match happens earlier in the strategy chain). For legacy URL-only references on these hosts, users may see a duplicate on re-paste and can dedupe manually. A future commit could either (a) one-shot canonicalize URL fields on next launch (migration), or (b) extend `findDuplicateReferenceID` to also try a canonicalized comparison via a Swift-side scan.
