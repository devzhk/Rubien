# CVF Open Access citation_* fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the bug where `Add by Identifier` rejects CVF Open Access URLs (e.g. `openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_...html`) with "Could not find BibTeX on this CVF page" even though the page exposes complete metadata.

**Architecture:** Drop the special-case CVF BibTeX adapter (`PaperURLResolver.resolveCVF`) and route CVF through the standard `resolveCitationMeta` path used by the other 9 hosts. The original spec assumed CVF pages had no `citation_*` meta tags and a `<pre>` BibTeX block — both assumptions are false on real CVF pages across all venues sampled (CVPR 2018, 2019, 2025). The real pages have `citation_*` meta tags that pass the strong evidence gate cleanly.

**Tech Stack:** Swift 6, GRDB 7.10, macOS 15. Same as the parent feature (`Docs/plans/2026-05-16-paper-url-resolver.md`).

**Pre-flight check before starting:**

```bash
cd /Users/hzzheng/CodeHub/Rubien
swift build              # must succeed
swift test 2>&1 | tail -5   # 732/732 pass (4 env-gated skipped)
git status               # clean (the mac-auto-updater untracked files are pre-existing)
git log --oneline -1     # should be 7116879 simplify pass
```

---

## Bug summary

User reported pasting `https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html` into Add-by-Identifier failed.

Trace:

1. `MetadataFetcher.extractIdentifier` recognized the URL as `.paperURL` (path matches `^/content/[^/]+/html/.+\.html$`).
2. `PaperURLResolver.resolve` canonicalized the URL.
3. `KnownPaperHost.classify` returned `.cvfOpenAccess`.
4. Dispatch went to `resolveCVF` (the inline CVF BibTeX adapter).
5. `resolveCVF` fetched the page successfully (HTTP 200, ~6 KB HTML, text/html).
6. `resolveCVF` ran the regex `(?s)<pre[^>]*>(.+?)</pre>` to extract the BibTeX block. **No match** — CVF 2025 pages have no `<pre>` tags.
7. Threw `ResolveError.bibtexNotFound`.
8. `MetadataResolver.resolveIdentifierLocally`'s catch handler caught the throw and wrapped `error.localizedDescription` into a `.rejected(insufficientEvidence, ...)` envelope.
9. **User-visible message:** because `PaperURLResolver.ResolveError` has no `LocalizedError` conformance, `error.localizedDescription` falls back to a Foundation default form (the raw case name, e.g. `"bibtexNotFound"`). The friendly "Could not find BibTeX on this CVF page" string from the spec §4 error table is only documentation — it isn't actually emitted by the running code today. This narrative issue is **out of scope for this fix** (see Out of scope section) but acknowledges that the user's reported "it failed" came with a less-than-helpful error string.

## Root cause

The original spec made two assumptions that don't hold on real CVF pages:

1. **"CVF doesn't expose citation_* meta tags"** — wrong. CVPR 2018, 2019, 2025 (verified by direct `curl`) all expose `citation_title`, `citation_author` (multi), `citation_publication_date`, `citation_conference_title`, `citation_firstpage`, `citation_lastpage`, `citation_pdf_url`. (They do NOT expose `citation_doi` — CVF doesn't mint DOIs for proceedings papers.)

2. **"CVF pages contain exactly one `<pre>...</pre>`"** — wrong. The BibTeX block lives in `<div class="bibref pre-white-space">`, not `<pre>`. Confirmed by inspecting the live CVPR 2025 VGGT page:

```html
<div class="link2">[<a ...>bibtex</a>]
<div class="bibref pre-white-space">@InProceedings{Wang_2025_CVPR,
    author    = {Wang, Jianyuan and Chen, Minghao and ...},
    ...
}</div>
```

Both `<pre>` and `bibref` counts confirmed across three CVF venues (2018/2019/2025): `<pre>` = 0, `bibref` = 2, `citation_title` = 1+.

## Fix design

Route CVF through `resolveCitationMeta` like every other host. The custom BibTeX adapter becomes dead code and is removed.

The strong evidence gate (`citation_title` + ≥1 other) passes easily on CVF pages: title is always present, plus `citation_author` (multi) AND `citation_publication_date` AND `citation_conference_title`. The gate's purpose was to reject paywall pages — CVF pages aren't paywalled.

### Code changes

#### 1. `Sources/RubienCore/Services/PaperURLResolver.swift`

**In `resolve()`** (around line 51) — drop the CVF branch:

Before:
```swift
let outcome: Outcome
if host == .cvfOpenAccess {
    outcome = try await resolveCVF(landingURL: landingURL, session: session)
} else {
    outcome = try await resolveCitationMeta(landingURL: landingURL, host: host, session: session)
}
```

After:
```swift
let outcome = try await resolveCitationMeta(landingURL: landingURL, host: host, session: session)
```

(Or, if the current code is the simpler form `try await resolveCitationMeta(...)` already, this step is a no-op — but the call site still passes `host` so `resolveCitationMeta` can branch on it.)

**In `resolveCitationMeta()`** (around line 105) — set `metadataSource` based on host so CVF papers are labeled `.cvfOpenAccess`:

Before:
```swift
let ref = Reference(
    title: title,
    authors: meta.authors,
    ...,
    metadataSource: .publisherCitationMeta,
    ...
)
```

After:
```swift
let metadataSource: MetadataSource = (host == .cvfOpenAccess)
    ? .cvfOpenAccess
    : .publisherCitationMeta

let ref = Reference(
    title: title,
    authors: meta.authors,
    ...,
    metadataSource: metadataSource,
    ...
)
```

**Remove dead code:**
- The `resolveCVF` private func (was ~30 lines).
- The `cvfPreTagRegex` static let (was 1 line — pre-compiled `<pre>...</pre>` regex).

Optionally also drop the unused import of `BibTeXImporter` from this file if no other call site remains.

#### 2. `Sources/RubienCore/Services/PaperURLResolver.swift` (resolve() top doc)

If there's a comment block at the top of `resolve()` describing dispatch, update it: "CVF uses citation_* meta tags like every other host."

### Test changes

#### 3. Replace `Tests/RubienCoreTests/Fixtures/CitationMeta/cvf-paper.html`

Current (synthetic, wrong): the existing fixture has `<pre>` BibTeX content and no `citation_*` meta tags. Replace with a real-shape capture from CVPR 2025.

New content (mimics the VGGT page; trimmed for fixture brevity):

```html
<!--
SOURCE: https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html
CAPTURED: 2026-05-16 (real fixture replacing previous synthetic <pre>-based version)
-->
<!DOCTYPE html>
<html>
<head>
<title>CVPR 2025 Open Access Repository</title>
<meta name="citation_title" content="VGGT: Visual Geometry Grounded Transformer">
<meta name="citation_author" content="Wang, Jianyuan">
<meta name="citation_author" content="Chen, Minghao">
<meta name="citation_author" content="Karaev, Nikita">
<meta name="citation_author" content="Vedaldi, Andrea">
<meta name="citation_author" content="Rupprecht, Christian">
<meta name="citation_author" content="Novotny, David">
<meta name="citation_publication_date" content="2025">
<meta name="citation_conference_title" content="Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition">
<meta name="citation_firstpage" content="5294">
<meta name="citation_lastpage" content="5306">
<meta name="citation_pdf_url" content="https://openaccess.thecvf.com/content/CVPR2025/papers/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.pdf">
</head>
<body>
<div class="bibref pre-white-space">@InProceedings{Wang_2025_CVPR,
    author    = {Wang, Jianyuan and Chen, Minghao and Karaev, Nikita and Vedaldi, Andrea and Rupprecht, Christian and Novotny, David},
    title     = {VGGT: Visual Geometry Grounded Transformer},
    booktitle = {Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)},
    month     = {June},
    year      = {2025},
    pages     = {5294-5306}
}</div>
</body>
</html>
```

#### 4. Rewrite `testCVFLandingExtractsFromBibTeX`

Currently in `Tests/RubienCoreTests/PaperURLResolverTests.swift`. Rename to `testCVFLandingExtractsFromCitationMeta` and rewrite assertions:

```swift
func testCVFLandingExtractsFromCitationMeta() async throws {
    StubURLProtocol.stub(
        "https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html",
        body: loadFixture("cvf-paper")
    )

    let outcome = try await PaperURLResolver.resolve(
        URL(string: "https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html")!,
        session: StubURLProtocol.makeSession()
    )

    XCTAssertEqual(outcome.reference.title, "VGGT: Visual Geometry Grounded Transformer")
    XCTAssertEqual(outcome.reference.referenceType, .conferencePaper)
    XCTAssertEqual(outcome.reference.metadataSource, .cvfOpenAccess)
    XCTAssertEqual(outcome.reference.authors.count, 6)
    XCTAssertEqual(outcome.reference.authors.first?.family, "Wang")
    XCTAssertEqual(outcome.reference.year, 2025)
    XCTAssertEqual(outcome.reference.pages, "5294-5306")
    XCTAssertEqual(outcome.scrapedPDFURL, "https://openaccess.thecvf.com/content/CVPR2025/papers/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.pdf")
}
```

The earlier test exercised the BibTeX path. The new test exercises the citation_meta path. Functionally equivalent contract; different mechanism.

#### 5. Optional — remove obsolete error rows

`Sources/RubienCore/Services/PaperURLResolver.swift` `ResolveError`:
- `.bibtexNotFound` becomes unreachable code (no path to it).
- `.bibtexEmpty` becomes unreachable code.

Decision: **keep them** for now. Switch exhaustiveness in the catch handlers may still need them, and removing them changes the public-ish enum surface. The dead code is a couple of enum cases — keep as defensive scaffolding. A future commit can prune if no caller cares.

### Tests we are NOT writing

- A live smoke test for CVF (Task 7 already added two gated smoke tests for OpenReview and ACL; CVF can be added there in a follow-up). Out of scope for this fix.
- A regression test for the original bug condition (`<pre>` absent). The replaced fixture is the regression test — it has the real CVF structure, no `<pre>`, and the resolver succeeds.

## Implementation order

Single commit. Steps:

1. **Update the fixture** (`Tests/RubienCoreTests/Fixtures/CitationMeta/cvf-paper.html`). Run only the parse test to verify the new fixture has valid HTML: `swift test --filter CitationMetaScraperParseTests 2>&1 | tail -5`. (Note: the existing parse test for the cvf fixture may need updating; check.)

2. **Update `resolveCitationMeta`** to set `metadataSource` based on host.

3. **Drop the `if host == .cvfOpenAccess` branch** in `resolve()`. The dispatch now always calls `resolveCitationMeta`.

4. **Remove dead code:** `resolveCVF` private func and `cvfPreTagRegex` static let.

5. **Update the test** (`testCVFLandingExtractsFromBibTeX` → `testCVFLandingExtractsFromCitationMeta`).

6. **Verify build + full test suite:**
   ```bash
   swift build 2>&1 | tail -3
   swift test 2>&1 | tail -10
   ```
   All 732 tests should pass (with the renamed test now covering the new path). Note: if `CitationMetaScraperParseTests` had a fixture-specific assertion on `cvf-paper.html`'s `<pre>` content, that assertion needs updating too — check first.

7. **Manual smoke test** (optional; do if you can run the Mac app):
   - `swift run Rubien`
   - Paste `https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html` in Add-by-Identifier.
   - Expect: verified card showing "VGGT: Visual Geometry Grounded Transformer" with 6 authors, year 2025, CVPR conference, "Also download PDF" toggle enabled.

8. **Commit:**
   ```
   git add Sources/RubienCore/Services/PaperURLResolver.swift \
           Tests/RubienCoreTests/Fixtures/CitationMeta/cvf-paper.html \
           Tests/RubienCoreTests/PaperURLResolverTests.swift
   git commit -m "RubienCore: route CVF Open Access through citation_meta scraper

   The original spec assumed CVF pages had no citation_* meta tags
   and used <pre>...</pre> for BibTeX. Both assumptions were wrong:
   - CVPR 2018, 2019, 2025 (verified) all expose citation_title,
     citation_author (multi), citation_publication_date,
     citation_conference_title, citation_firstpage/lastpage,
     citation_pdf_url.
   - BibTeX lives in <div class=\"bibref pre-white-space\">, not <pre>.

   Drop the resolveCVF BibTeX adapter; route CVF through
   resolveCitationMeta like the other 9 hosts. CVF papers still get
   the .cvfOpenAccess metadataSource label for provenance. PDF
   auto-download now works for CVF papers (citation_pdf_url is more
   reliable than the previous string-replace synthesis).

   Reported by user on commit 7116879: VGGT paper at
   openaccess.thecvf.com/content/CVPR2025/.../html/...html failed
   with 'Could not find BibTeX on this CVF page'.

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

## Risk assessment

**Low.** The fix removes code rather than adding it; the citation_meta path is already exercised by 9 other hosts and 200+ tests. The strong evidence gate already correctly distinguishes valid paper pages from paywalls.

**Backward compatibility:** Existing CVF references in users' libraries are unaffected. The `MetadataSource.cvfOpenAccess` case is preserved and continues to label CVF papers in the UI.

**Regression risk:** The replaced fixture covers a real CVPR 2025 page shape. If CVF ever removes `citation_*` meta tags (unlikely; they've had them since at least 2018), the strong evidence gate will reject and the user will see a clear "Page did not expose paper metadata" message — same failure mode as a paywall-blocked publisher page.

## Out of scope

- A CVF live smoke test. Add later via `Scripts/refresh-citation-fixtures.sh` + a new `testCVFLive` in `PaperURLLiveSmokeTests.swift`.
- Pruning the `.bibtexNotFound` and `.bibtexEmpty` `ResolveError` cases (unreachable after this fix). Defensive enum cases — keep until a future cleanup commit.
- Removing the `BibTeXImporter` import from `PaperURLResolver.swift` if no other call site remains. Negligible.
- **`LocalizedError` conformance for `PaperURLResolver.ResolveError`.** Currently `error.localizedDescription` on these cases falls back to Foundation's default (raw case name), so user-facing rejection strings show "bibtexNotFound" / "insufficientMetadata" / etc. rather than the friendly spec-§4 wording. A follow-up commit could add the conformance with mappings to friendly text. Not blocking this CVF fix — after the fix, the success path is exercised and users won't see these errors on CVF URLs anyway.

## Post-fix failure mode (note for future maintainers)

After this fix, a CVF page that somehow lacks citation_* meta tags (workshop pages, supplementary pages, future CVF site redesign, or anti-bot interstitials) will fail the strong evidence gate and the resolver throws `ResolveError.insufficientMetadata`. There is no BibTeX-as-fallback because the inline `resolveCVF` adapter is gone. This is the intended failure mode: users see a clear "Page did not expose paper metadata" rejection (once `LocalizedError` is wired up — see follow-up above) instead of a confusing BibTeX-format error from a page that never had `<pre>` to begin with.
