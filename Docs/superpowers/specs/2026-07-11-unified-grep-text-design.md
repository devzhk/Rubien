# Unified Body-Text Grep (`rubien_grep_text`) — Design Spec

**Date:** 2026-07-11
**Status:** Draft for review
**Context:** Feature 2 of the two-feature arc. Feature 1 (unified read tools, merged at `880ddc6`) established the routing conventions this reuses: the four-state PDF availability probe, `source`/`available`, PDF-wins + param-implied source selection. This spec **supersedes** `Docs/superpowers/specs/2026-06-26-pdf-grep-design.md` (PDF-only draft, never implemented); its PDF matcher design is absorbed here. Nothing named `rubien_pdf_search` / `pdf search` ever ships.

## 1. Motivation

`rubien_search` finds *references* (metadata FTS across the library). `rubien_read_text` retrieves a *body*. Neither answers "**where** does reference 42's body say X" — today an agent must page the whole document through `read_text` and scan it. Grep is the lookup half of the read workflow: pattern in → anchored snippets out → `read_text` drills into the anchor. PDF hits anchor to **page numbers** (feed `read text --pages`); web hits anchor to **exact character offsets** (feed `read text --start`).

## 2. Goals / Non-goals

**Goals**
- One MCP tool searches the body text of *any* reference — attached PDF or clipped web page — with literal or regex queries, case-insensitive.
- Kind routing identical to `read_text` (same probe, same selection rules, same error strings), so grep and the follow-up read always land on the same body.
- PDF results grouped by page with `sectionPath` breadcrumbs and snippets; web results carry exact raw-body offsets consumable by `read text --start`.
- Bounded, predictable output for an LLM context window; truncation is always visible in counts.
- Same algorithm and DTO on macOS (PDFKit) and Linux (poppler), built on `PDFExtractor`'s per-page extraction. Best-effort comparable across backends, not byte-identical.

**Non-goals (v1)**
- No `--source all` (searching both bodies in one call) — reserved as future work; one body per call, chosen by the read_text rules.
- No reader-grade highlight geometry; the Mac reader's `findString` path stays separate.
- No OCR (scanned PDFs return `hasTextLayer:false` + empty hits, signalling the `rubien_pdf_page_image` fallback).
- No `--section`-scoped search (callers filter the returned `sectionPath`); no cross-reference/multi-document search; no relevance ranking (document order).

## 3. Tool surface

### MCP (both catalogs, in lockstep)

New tool `rubien_grep_text` registered alongside the read tools — Node `mcp-server/src/tools/read.ts` and Swift `MCPToolCatalog.swift`. Counts: Node server 34 → 35; native read-only catalog 7 → 8. Tool descriptions form a routing triangle, each naming its neighbors: `rubien_search` = which *references* match (library metadata); `rubien_grep_text` = *where* one reference's body says it; `rubien_read_text` = retrieve the located text. `rubien_read_text`'s description gains one sentence pointing at grep for locating.

### CLI

Top-level subcommand (the name is free; grep is a verb like `search`):

```
rubien-cli grep <id> <query> [--regex] [--source pdf|web] [--context-chars N]
    [--pages <range>] [--max-pages N] [--snippets-per-page N]   # PDF-scoped
    [--max-matches N]                                            # web-scoped
```

JSON to stdout like every other subcommand. New subcommand ⇒ version-floor bump (§8).

## 4. Routing

Identical to `read_text`, reusing `resolveSources(for:)` / `PDFSourceState` / `pdfStateDescription(_:)` verbatim:

1. Explicit `--source` wins; requesting an unavailable source errors (message carries the PDF state + `available`, same strings as `read text`).
2. Kind-scoped params imply the source: `--pages`/`--max-pages`/`--snippets-per-page` → pdf; `--max-matches` → web. The implied source must be available. Mixing families errors.
3. Otherwise PDF wins when both are available.

Every response carries `source` and `available` (ordered `["pdf","web"]`). Neither available / missing ref: same errors as `read text`.

## 5. Contract

### Parameters

| Param | Applies to | Semantics |
|---|---|---|
| `id` (required) | — | reference id |
| `query` (required) | both | literal phrase (default) or regex (`--regex`); empty/whitespace-only → validation error |
| `regex` | both | treat `query` as a regex; compile failure → `invalid-regex` error |
| `source` | both | `pdf` \| `web`; overrides selection rules |
| `contextChars` | both | snippet window width, default 160 (≈80 per side, trimmed to whitespace), bounds 1–2000 enforced in the CLI (zod repeats the bound; Swift catalog advertises it — the `maxChars` precedent) |
| `pages` | PDF only | restrict search scope, e.g. `1-3,8-10` — reuses the `read text --pages` range parser. **Empty-string pinning (feature-1 parity rule):** both MCP catalogs treat `pages:""` as absent (neither implies pdf nor emits the flag); the CLI treats a supplied empty `--pages ""` as PDF-implying with full-document scope, matching `read text` |
| `maxPages` | PDF only | cap returned page-hits, default 30, bounds 1–200 |
| `snippetsPerPage` | PDF only | default 3, bounds 1–20 |
| `maxMatches` | web only | cap returned match *entries* (post-merge clusters, §5), default 20, bounds 1–200 |

Matching is **case-insensitive** on both paths (regex can scope case back on with inline `(?-i:…)`).

**Occurrence semantics (both paths, literal and regex):** matches are **non-overlapping, leftmost-first** — after a match, scanning resumes at its end (standard find-next semantics), so `"aa"` in `"aaa"` counts 1, not 2. **Zero-width matches are discarded entirely**: they never produce entries or counts, and enumeration advances one grapheme past each so it cannot loop; a pattern that matches only the empty string (`^`, `$`, `\b`, `a?` against no `a`) yields `totalMatches: 0`, not a match per position.

### Envelopes (the `read_text` pattern: per-source shape + `source`/`available`)

PDF source:

```json
{ "id": 42, "source": "pdf", "available": ["pdf", "web"],
  "query": "theorem", "isRegex": false,
  "pageCount": 12, "hasTextLayer": true,
  "totalMatches": 5, "totalMatchingPages": 2, "truncated": false,
  "pages": [
    { "page": 4, "sectionPath": ["3 Main Results"], "matchCount": 2, "snippetsTruncated": false,
      "snippets": ["… we now state the main result. Theorem 1 (Convergence). Let f be …"] },
    { "page": 7, "sectionPath": ["3 Main Results", "3.2 Proof of Theorem 1"], "matchCount": 3, "snippetsTruncated": false,
      "snippets": ["… Proof of Theorem 1. By the lemma above …"] }
  ] }
```

- Pages ascend in document order; `page` is 1-indexed; `sectionPath` is outermost→deepest, `[]` when no outline covers the page (normal, not an error).
- `totalMatches` / `totalMatchingPages` are counted across ALL matching pages in scope **before** the `maxPages` cut; `truncated` ⇔ `totalMatchingPages > pages.count`. `matchCount` is per-page occurrences before the snippet cap; `snippetsTruncated` (per page) is true when `snippetsPerPage` dropped merged windows, so cap-driven omission is distinguishable from window merging.
- PDF snippets are drawn from **normalized** text (§6) — not byte-identical to `read text` output; page numbers, not offsets, are the PDF anchor.

Web source:

```json
{ "id": 7, "source": "web", "available": ["web"],
  "query": "theorem", "isRegex": false,
  "contentLength": 84213, "totalMatches": 3, "totalEntries": 2, "truncated": false,
  "matches": [
    { "start": 18342, "matchCount": 2, "snippet": "… we now state the theorem …" }
  ] }
```

- `start` is the exact offset of the entry's first match in the **raw decoded body**, in the same grapheme-count coordinates `read text` already uses for `start`/`contentLength`/`returnedChars` — so `read text <id> --start <start-N> --max-chars M` drills straight in. **Invariant:** every returned range lies on `Character` (grapheme) boundaries and `start == body.distance(from: body.startIndex, to: range.lowerBound)`; the matcher must not surface sub-Character indices from any semantic mode. The integration test (§9) enforces the contract end to end, including combining marks and emoji.
- **Merge rule:** each match gets a window of ≈`contextChars/2` per side (clamped to the body); overlapping/adjacent windows merge into one entry whose `start` is the cluster's first match offset and `matchCount` the cluster's matches; the snippet spans the merged window, whitespace-collapsed for display and ellipsized at trimmed-to-whitespace edges. Entries ascend by `start`.
- **Counts:** `totalMatches` = raw (pre-merge) matches; `totalEntries` = merged clusters **before** the `maxMatches` cut; `maxMatches` caps returned entries; `truncated` ⇔ `totalEntries > matches.count`. Truncation is thus visible in counts on both paths (`totalEntries` is the web analog of PDF's `totalMatchingPages`).
- `contentLength` mirrors `read text`'s field (total decoded body length) so the caller can window sensibly.

## 6. Matchers

### PDF (absorbed from the June draft, unchanged in substance)

Grep over the **extracted text layer** via `PDFExtractor`'s per-page extraction and page→section mapping — deliberately not the reader's `findString`/`poppler_page_find_text` (those exist to produce highlight geometry; the section breadcrumb comes from the matched page number either way, and extracted-text matching buys regex + one cross-platform code path). The matcher sits behind a small internal boundary so a native-find backend could replace it later without changing the CLI/MCP contract.

Per candidate page (all pages, or those in `--pages`), in document order: extract text → normalize → find all matches → build snippets (per-match windows, merged when overlapping, capped at `snippetsPerPage`) → record the page-hit. `hasTextLayer` is true iff **any** candidate page yielded non-empty extracted text (more accurate than `pdf info`'s sampled probe).

**Normalization** (applied identically to page text and, on the literal path, the query):
- Unicode **NFKC** (`precomposedStringWithCompatibilityMapping`) — folds ligatures (ﬁ→fi) and width variants.
- Strip soft hyphens (`U+00AD`) — NFKC does not remove them.
- Join end-of-line **hyphenation**: `-` + line break + lowercase letter → drop both, *before* whitespace-collapse. Accepted, tested limitations: misses a backend that already spaced the break (`exam- ple`); falsely fuses a genuine compound broken at line end (`non-\nlinear` → `nonlinear`). Preferable to wrecking real hyphenated compounds.
- Collapse whitespace runs to single spaces; trim.

Because matching and snippet extraction both operate on the normalized string, there is **no raw↔normalized offset mapping** on the PDF path — page numbers are the anchor.

**Regex on the PDF path** runs against post-normalization text: author with `\s` or literal spaces (never `\n`), `^`/`$` anchor the whole page string; the user's pattern is *not* itself NFKC-folded (a literal `ﬁ` in a pattern won't match folded text — author ASCII patterns). Documented and tested.

### Web

Case-insensitive matching over the **raw decoded body** — the exact string `read text` serves. No normalization: the reader-extraction pipeline (Defuddle/Readability) already emits clean text, and skipping it is what makes offsets exact and free. `^`/`$` anchor the whole body; `\n` is matchable (the body is raw). HTML-format bodies (`contentFormat:"html"`, the rare case) are grepped as-is — matches may land in markup; offsets stay `read text`-consistent, which beats tag-stripping that would desynchronize the two tools. Documented in the tool description.

**Regex engine (both paths):** Swift native `Regex` (Swift 6, Linux-capable), matching and slicing on `String.Index` — never integer/UTF-16 offsets (multi-byte correctness). Occurrence and zero-width semantics are pinned in §5 (non-overlapping leftmost-first; zero-width matches discarded).

### Placement (refines the June draft's ambiguity)

The normalizer + literal/regex matcher + snippet-windowing live in **RubienCore** (new `Sources/RubienCore/Services/BodyTextMatcher.swift` or similar), because pure-logic unit tests must run on Linux CI and `RubienPDFKitTests` is Mac-only (poppler test-bundle linking hang). Dependency direction verified against `Package.swift`: `RubienPDFKit` already depends on `RubienCore` (and `PDFExtractor.swift` already imports it), so `PDFExtractor.search` calling the shared matcher introduces no cycle. (Note: CLAUDE.md's architecture blurb states the dependency backwards; fixed alongside this spec.) `PDFExtractor.search(...)` (RubienPDFKit) does per-page extraction + section mapping and calls the shared matcher; the CLI `Grep` subcommand does probe → route → matcher → envelope, with the web path calling the matcher directly on the decoded body.

## 7. Error handling

| Condition | Result |
|---|---|
| Reference not found | error `"Reference N not found"` (same as `read text`) |
| Neither source available | same per-state error as `read text` |
| Requested/implied source unavailable | same error incl. PDF state + `available` |
| Param families mixed (pdf-scoped + `--max-matches`) | error, mutually exclusive |
| Explicit `source` contradicts a kind-scoped param | error incl. requested source + `available` (post-probe, `read text` pattern) |
| Empty / whitespace-only query | validation error |
| Invalid regex (`--regex`) | `invalid-regex` error |
| PDF extraction failure post-probe (encrypted / cannot-open / invalid or out-of-range `--pages`) | pass through the existing structured `PDFExtractor.ExtractError` envelope via `emitPDFExtractError`, exactly as `read text` does — no new error shapes |
| Scanned PDF / no text layer | **success**: `hasTextLayer:false`, `pages:[]`, `totalMatches:0` — description tells the agent to fall back to `rubien_pdf_page_image` |
| Text present, term absent | **success**: empty hits, `totalMatches:0` (both sources) |
| PDF without outline | **success**: `sectionPath:[]` per hit (grep never needs the outline; unlike `read text --section`'s `no-outline` error, which is a selection failure) |
| Bounds violations (`contextChars`, `maxPages`, `snippetsPerPage`, `maxMatches`) | CLI validation error (zod repeats the bounds) |

## 8. Versions

New CLI subcommand the new server tool depends on ⇒ `BUILD.txt` 20 → **21**, `MIN_CLI_BUILD` → **21**, regenerate `GeneratedVersion.swift` (build 21) in the same task. npm package stays **0.2.0** — it is still unpublished, so grep is absorbed before first publish (contingency: if 0.2.0 has shipped by implementation time, bump to 0.3.0 instead). `SERVER_INFO` unchanged unless that contingency triggers.

## 9. Testing

- **BodyTextMatcher unit tests (RubienCoreTests — run on Linux CI):** NFKC ligature fold; soft-hyphen strip; hyphenation join incl. the documented `non-\nlinear` false-join and `exam- ple` miss; whitespace collapse; non-overlapping leftmost-first occurrence counting (`"aa"` in `"aaa"` = 1); zero-width discard for `^`, `$`, `\b`, and an optional-empty pattern, each independently; regex-`ﬁ`-doesn't-match-`fi`; case-insensitivity both paths; web-path exactness — grapheme-boundary offsets with multi-byte, emoji, **and decomposed combining-mark** fixtures asserting `start == body.distance(from:to:)`, window merge/adjacency, `maxMatches` entry cap + `totalMatches`/`totalEntries` counting + `truncated`, snippet trim/ellipsis, per-page `snippetsTruncated`.
- **CLI contract tests (RubienCLITests, ReadCommandTests patterns + seeding helpers):** routing matrix (pdf-only / web-only / both + PDF-wins + `--source web` flip / param-implied / mixed-family error / contradiction error / neither / missing ref); web happy path with seeded body asserting exact `start` values; **the coordinate integration test**: grep a seeded web body, feed the returned `start` into `read text --start`, assert the window contains the match — run twice, once on a markdown body and once on a seeded **HTML-format body with the match inside markup**, so the raw-HTML offset compatibility is pinned too; bounds validation for all four capped params; empty-query and invalid-regex errors.
- **Mac-gated PDF acceptance (`#if canImport(PDFKit)`):** fixture-driven — page numbers, `matchCount`, `totalMatchingPages`, `truncated` (force with `--max-pages 1`), `--pages` scoping incl. an **out-of-range/invalid range → ExtractError pass-through** case, `--regex`, no-match-with-text-layer, and a **scanned/no-text-layer fixture → success with `hasTextLayer:false`, empty pages**. `sectionPath` assertions need an outlined fixture; `linear-3pages-text.pdf` has no outline, so either add a small outlined fixture or assert `sectionPath == []` on the existing one at the grep boundary and cover section mapping in RubienPDFKitTests' existing outline coverage (decide in the plan).
- **MCP layers:** `MCPServerTests` (catalog entry, required args, argv construction incl. both param families, mutual-exclusion pre-checks mirroring Node) + vitest (registration, zod mirrors for both envelopes in `schemas.ts` + `schemas.test.ts` pinning, e2e tool-list).
- **Linux backend acceptance:** via `scripts/run-linux-parity-tests.sh`, same DTO shape, best-effort comparable results (looser than byte-equality).

## 10. Docs (same commit as code — lockstep rule)

- `Docs/CLI-Reference.md`: `## grep` section after `## read` (synopsis, both JSON shapes, the routing rules by reference to `read`, error modes, the offset-coordinate contract); MCP mapping table gains the `rubien_grep_text` → `grep` row.
- `mcp-server/README.md`: Reading row gains `rubien_grep_text`; tool count 34 → 35; one prose sentence on the grep→read workflow.
- Tool descriptions (§3 routing triangle) are the agent-facing docs; keep both catalogs byte-identical (feature-1 precedent: Node `read.ts` is authored first and is canonical).

## 11. Future work

`--source all` (search both bodies in one call); `--section`-scoped search; OCR fallback for scanned PDFs; native-find backend behind the matcher boundary if extracted-text recall proves insufficient; relevance ranking.
