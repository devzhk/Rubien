# PDF Content Search ("pdf grep") — Design Spec

**Date:** 2026-06-26
**Status:** SUPERSEDED by `2026-07-11-unified-grep-text-design.md` — the kind-agnostic `rubien_grep_text` revision absorbed this draft's PDF matcher design; nothing named `rubien_pdf_search` / `pdf search` ships. Kept for history.
**Context:** brainstormed collaboratively; design only — no implementation yet.

## 1. Motivation

`rubien_search` / `rubien-cli search` is full-text over **library metadata only** (title, authors, abstract, notes, journal, DOI, publisher, ISBN, etc.). It never looks inside a PDF's body. So an agent cannot answer locating questions like *"where do they state the theorem, and where is the proof?"* about an attached paper.

This feature adds **body-text search** over a reference's attached PDF that returns **page numbers + section breadcrumbs + snippets**. Claude (via MCP) or a script (via CLI) can pinpoint where a concept appears, then drill in with the existing `pdf text` / `pdf page-image`.

## 2. Goals / Non-goals

**Goals**
- Search the body text of a reference's attached PDF for a literal phrase or a regex.
- Return results grouped by page, each with section path, match count, and readable snippets.
- Run the **same algorithm and return the same DTO** on macOS (PDFKit) and Linux (poppler) by building on the existing `PDFExtractor`. Results are *best-effort comparable*, not byte-identical across platforms — the two backends extract text through different engines (`page.string` vs `poppler_page_get_text`) and can diverge on column/reading order, hyphenation, ligature expansion, and where line breaks fall (see §3).
- Bounded, predictable output suitable for an LLM context window.

**Non-goals (v1)**
- Reader-grade visual selection geometry / highlight bounds. The Mac reader's `findString` path stays separate.
- OCR of scanned PDFs. No text layer → empty result plus a signal to use page images.
- Section-scoped search (`--section`). Deferred; callers filter the returned `sectionPath` themselves.
- Cross-reference / multi-PDF search. One reference per call.

## 3. Approach

Reuse `PDFExtractor`'s per-page extraction and page→section mapping (the loop at `Sources/RubienPDFKit/PDFExtractor.swift:274–284`) and grep over the **extracted text layer**.

We deliberately do **not** use the reader's native `findString` (PDFKit) / `poppler_page_find_text`. Those primitives exist to produce highlight geometry the reader needs to *draw* selections — which this consumer never uses. Grepping the extracted layer instead gives us regex, snippets, and a single cross-platform code path. Crucially, the section breadcrumb (the thing callers actually want) is computed from the matched **page number** regardless of how matches are found, so a native-find primitive would save none of that work while costing two per-backend implementations and losing regex.

**Known limitation:** matching is over the extracted text layer, so it is not byte-identical to the reader's `findString` (ligatures, math spacing, odd kerning). Normalization (§7) closes the common gaps. Scanned PDFs with no text layer return nothing — surfaced via `hasTextLayer` so the caller can fall back to `pdf page-image`.

The matcher lives behind a small internal boundary so a native-find backend could replace it later — without changing the CLI/MCP contract — if extracted-text recall ever proves insufficient.

## 4. Result shape (page-grouped)

Swift DTO:

```swift
struct PdfSearchOutput: Codable {
    let id: Int64
    let query: String
    let isRegex: Bool
    let pageCount: Int          // total pages in the PDF (mirrors `pdf text` / `pdf info`)
    let hasTextLayer: Bool
    let totalMatches: Int       // total occurrences across ALL matching pages in scope,
                                // counted BEFORE truncation
    let totalMatchingPages: Int // how many pages matched in scope, BEFORE truncation
    let truncated: Bool         // true when totalMatchingPages > pages.count (maxPages cut the list)
    let pages: [PageHit]

    struct PageHit: Codable {
        let page: Int               // 1-indexed
        let sectionPath: [String]   // outermost→deepest; [] when no outline covers the page
        let matchCount: Int         // occurrences on this page (before snippet cap)
        let snippets: [String]      // up to snippetsPerPage; drawn from NORMALIZED text
                                    // (NFKC-folded, whitespace-collapsed) — not byte-identical
                                    // to `pdf text` output
    }
}
```

Example (`query: "theorem"`):

```json
{
  "id": 42, "query": "theorem", "isRegex": false, "pageCount": 12, "hasTextLayer": true,
  "totalMatches": 5, "totalMatchingPages": 2, "truncated": false,
  "pages": [
    { "page": 4, "sectionPath": ["3 Main Results"], "matchCount": 2,
      "snippets": ["… we now state the main result. Theorem 1 (Convergence). Let f be …"] },
    { "page": 7, "sectionPath": ["3 Main Results", "3.2 Proof of Theorem 1"], "matchCount": 3,
      "snippets": ["… Proof of Theorem 1. By the lemma above, the sequence …"] }
  ]
}
```

Pages are returned in ascending document order. This maps directly onto the motivating query: *stated* on p.4 (§3), *proved* on p.7 (§3.2), and the page numbers are the actionable unit for any follow-up `pdf text --pages` / `pdf page-image --page` call.

## 5. CLI surface

```
rubien-cli pdf search <id> "<query>" [--regex] [--pages <range>]
    [--max-pages N] [--snippets-per-page N] [--context-chars N]
```

- `<id>` — reference id. `<query>` — literal phrase (default) or regex (`--regex`).
- `--pages <range>` — restrict search scope, e.g. `1-3,8-10` (reuses the range parser already used by `pdf text`).
- `--max-pages` default **30**; `--snippets-per-page` default **3**; `--context-chars` default **160** (≈80 each side of a match, trimmed to the nearest space).
- The CLI clamps/rejects out-of-range option values consistently with the MCP caps (§6: `maxPages` ≤ 200, `snippetsPerPage` ≤ 20, `contextChars` ≤ 2000), so the two front doors can't accept divergent inputs.
- Matching is **case-insensitive** for both substring and regex. (Regex callers can scope case back on with inline `(?-i:…)`.)
- JSON (the `PdfSearchOutput` shape) to stdout.
- New `PdfSearch` subcommand + `PdfSearchOutput` DTO in `Sources/RubienCLI/RubienCLI.swift`, registered alongside the other `Pdf` subcommands (`PdfInfo`, `PdfText`, `PdfPageImage`, `PdfStatus`, `PdfDownload`).

## 6. MCP tool

`rubien_pdf_search`, `readOnlyHint: true`, in `mcp-server/src/tools/pdf.ts`:

```ts
inputSchema: {
  id: z.number().int(),
  query: z.string().min(1),
  regex: z.boolean().optional(),
  pages: z.string().optional(),
  maxPages: z.number().int().positive().max(200).optional(),
  snippetsPerPage: z.number().int().positive().max(20).optional(),
  contextChars: z.number().int().positive().max(2000).optional(),
}
```

Maps to CLI flags via `flagsFromOptions`. The response schema is mirrored in `mcp-server/src/schemas.ts` (contract-pinning rule). The tool description instructs the model:
- returns page + section locations with snippets;
- when `hasTextLayer: false` (scanned PDF), fall back to `rubien_pdf_page_image`;
- for outline-less PDFs, `sectionPath` is `[]` and that is normal, not an error.

## 7. Core algorithm — `PDFExtractor.search(...)`

```swift
func search(_ query: String,
            isRegex: Bool = false,
            pageRange: PageRange? = nil,
            maxPages: Int = 30,
            snippetsPerPage: Int = 3,
            contextChars: Int = 160) throws -> PdfSearchResult
```

(Exact param/type names — `PageRange`, `PdfSearchResult` — finalized in the implementation plan; `pageRange` reuses whatever `extractText(at:selection:maxChars:)` already accepts.)

Steps:
1. Resolve candidate pages: all pages, or those inside `pageRange`.
2. Build the matcher once: literal → case-insensitive substring over normalized text; `isRegex` → compile a case-insensitive regex, throwing `invalid-regex` on a compile failure.
3. Normalize the query the same way page text is normalized (below) — for the literal path; for regex, the pattern is applied to normalized page text.
4. For each candidate page in document order:
   1. `text = page.extractedText() ?? ""`; `norm = normalize(text)`.
   2. Find all match ranges in `norm`. If none, skip the page.
   3. `sectionPath = sections.flatMap { sectionPath(forPage: p, in: $0) }` (existing helper); `[]` when no outline covers the page.
   4. Build snippets: for each match in order, take a window of ≈`contextChars/2` on each side, trim to whitespace boundaries, ellipsize; **merge overlapping windows** so near-adjacent matches don't yield near-duplicate snippets; cap at `snippetsPerPage`.
   5. Record `PageHit(page, sectionPath, matchCount, snippets)`; add `matchCount` to `totalMatches`.
5. `hasTextLayer`: true if **any** candidate page yielded non-empty extracted text. (More accurate than `pdf info`'s sampled probe, since search reads every candidate page anyway.)
6. `totalMatchingPages = matchingPages.count`; `truncated = totalMatchingPages > maxPages`; keep the first `maxPages` page-hits in ascending order. `totalMatches` and `totalMatchingPages` are both counted across all matching pages **before** this cut, so a consumer can tell that a truncated result hid pages. `pageCount` is the document's total page count (as `pdf text` / `pdf info` report).

**Normalization** (applied identically to page text and, for the literal path, the query):
- Unicode **NFKC** (`precomposedStringWithCompatibilityMapping`) — folds ligatures (ﬁ→fi) and width variants.
- Strip Unicode **soft hyphens** (`U+00AD`) entirely (NFKC does not remove them).
- Join end-of-line **hyphenation**: a `-` followed by a line break and a lowercase letter → drop the hyphen and the break (`exam-\nple` → `example`). This runs **before** whitespace-collapse, while the newline is still present. Known limitations (accepted, and tested): it does not catch a backend that already turned the break into a space (`exam- ple`), and it will incorrectly fuse a genuine compound that broke at a line end (`non-\nlinear` → `nonlinear`). We accept these over the alternative — joining every `hyphen + space + lowercase` — which would wreck real hyphenated compounds like `well- known`.
- Collapse all whitespace runs (newlines, tabs, multiple spaces) to a single space; trim.

Because both matching and snippet extraction operate on the normalized string, there is **no raw↔normalized offset mapping** to maintain, and snippets render cleanly.

**Regex against normalized text:** patterns run against the post-normalization string — whitespace collapsed to single spaces, line breaks removed, ligatures folded. Author patterns accordingly: use a literal space or `\s` rather than `\n`, and expect `^`/`$` to anchor the whole page string, not visual lines. The user's regex pattern is **not** itself NFKC-folded (that could corrupt the pattern syntax); only the page text is. A consequence: a literal `ﬁ` ligature *in a pattern* will not match the folded `fi` in page text — author patterns with plain ASCII. (Documented and tested.)

**Regex implementation:** use Swift's native `Regex(_ pattern: String)` (Swift 6, available on Linux too) so matching and snippet slicing both operate on `String.Index`. Avoid `NSRegularExpression`, whose UTF-16 `NSRange` must be converted via `Range(_:in:)` before slicing — integer/UTF-16 slicing of a Swift `String` is a correctness bug with multi-byte text and is the same hazard for literal-match snippet windows (slice on `String.Index`/grapheme boundaries, never integer offsets). Guard **zero-length matches** (`^`, `\b`, `.*?`): after an empty match, advance the search position by at least one grapheme so enumeration can't loop forever, and treat a pattern that matches the empty string everywhere as a no-op rather than reporting a match per position.

## 8. Error handling

| Condition | Result |
|---|---|
| No PDF attached / reference not found | the **same error envelope the other `pdf` subcommands already emit** via `resolveReferencePDFURL` — a generic JSON error message, *not* a new structured `no-pdf` code. Align with current behavior rather than inventing a code. |
| Empty / whitespace-only query | validation error (new to `search`) |
| Invalid regex (with `--regex`) | `invalid-regex` error (new to `search`) |
| Scanned / no text layer | **success**: `hasTextLayer:false`, `pages:[]`, `totalMatches:0` |
| Text layer present, term absent | **success**: `pages:[]`, `hasTextLayer:true` |
| PDF has no outline | **success**: each `sectionPath:[]` |

Only `invalid-regex` and the empty-query validation error are new to `search`; reference-resolution / no-PDF reuse the existing CLI error envelope so callers see consistent shapes across `pdf` subcommands.

A non-empty result on an outline-less PDF is intentional, and differs from `pdf text --section`, which errors `no-outline`. Search never needs the outline to function — it only enriches results with it when present.

## 9. Testing

Three layers, because true cross-backend parity cannot be asserted in one Mac-only target:

- **Pure normalizer + matcher unit tests** (platform-independent — keep them free of poppler linking so they run on every CI, Linux included): `normalize(...)` for NFKC ligature fold, soft-hyphen strip, end-of-line hyphenation join (including the documented `non-\nlinear` false-join and the `exam- ple` miss), and whitespace collapse; plus the matcher's zero-length-regex guard and the regex-`ﬁ`-doesn't-match-`fi` case. This is the bulk of the logic and the cheapest to run.
- **Darwin-backed acceptance tests** (Mac-only, where the existing `PDFExtractor` tests live): a fixture PDF with a known outline; assert page numbers, `sectionPath`, `matchCount`, `pageCount`, `totalMatchingPages`, and `truncated` for known terms, plus `--regex`, `--pages` scope, no-match-with-text-layer, and a no-text-layer fixture for `hasTextLayer:false`. These exercise the PDFKit backend only.
- **Linux backend acceptance** via the existing `scripts/run-linux-parity-tests.sh` path (poppler can't be linked into the Linux XCTest bundle — see CLAUDE.md). Assert the same DTO *shape* and best-effort comparable results (looser than byte-equality), so genuine cross-backend divergence is caught manually, not assumed away.

Contract tests:
- **RubienCLITests**: `pdf search` JSON-contract stability (key set + shape) against the built `rubien-cli`.
- **`mcp-server/test/schemas.test.ts`**: pin `PdfSearchOutput` in `src/schemas.ts` (the zod DTO mirror), alongside the other DTO mirrors, so the MCP contract can't drift silently from the Swift DTO.

## 10. Docs (same commit as code — CLI/data-layer lockstep rule)

- `Docs/CLI-Reference.md`: a new `pdf search` entry — synopsis, flags, JSON shape, examples, error modes.
- `mcp-server/README.md`: add `rubien_pdf_search` to the PDFs row of the tool catalog and to the PDF-tools paragraph.

## 11. Future work

- Native-find backend behind the matcher boundary, if extracted-text recall proves insufficient.
- `--section`-scoped search.
- OCR fallback for scanned PDFs (large; a separate feature).
- Optional relevance ranking (today: document order).
