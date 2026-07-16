# KaTeX Re-render for `<math data-latex>` Elements

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `\textcolor` (and similar LaTeX-specific styling commands) render correctly in the web reader for clips from Notion and other SPAs that emit math as raw LaTeX strings. Today, Defuddle's `/full` bundle converts those LaTeX strings into `<math data-latex="\textcolor{magenta}{...}">MathML</math>` elements during extraction, but the `temml` LaTeX→MathML converter inside `/full` does NOT translate `\textcolor` into any MathML equivalent — so the color is lost. The browser renders the bare MathML without color; KaTeX's auto-render in the reader sees no delimited-text LaTeX to render and stays out of the way.

**Architecture:** The reader already inlines KaTeX (CSS + `katex.js` + `auto-render.js`) into its head and calls `renderMathInElement(article, {...})` from `renderMath()` (`Sources/Rubien/Views/WebReaderView.swift:1164`). The fix adds ONE pre-step inside the same `renderMath()` function: before calling auto-render, walk `article.querySelectorAll('math[data-latex]')` and for each element call `katex.render(latex, newSpan, { displayMode, throwOnError: false })`, then `mathEl.replaceWith(newSpan)`. KaTeX's renderer handles `\textcolor` and the wider LaTeX color/styling vocabulary correctly. The existing `renderMathInElement` call stays as the legacy/fallback path for clips whose source HTML has delimited LaTeX text but no `<math>` elements.

**Tech Stack:** Pure JS edit inside a Swift triple-quoted string in `WebReaderView.swift`. No new dependencies, no new files, no Swift code change.

**Scope boundaries (NOT in this plan):**
- The Defuddle vendoring work at `scripts/clipper/` ships first (separate commit). This plan's commit lands on top.
- We do NOT modify Defuddle / temml. Upstream patch to temml is the long-term right fix but slow; this is a downstream workaround that gives correct rendering today.
- We do NOT touch the `Sources/Rubien/Services/ClipperWebMetadataExtractor.swift` extraction-time path. The wrapper produces `<math data-latex>` markup as-is; the fix is purely reader-side.
- We do NOT touch the 5s discriminator in `ReaderExtractionManager.swift` (still in working tree; reverted separately).
- We do NOT handle math that arrives in a non-`<math>` form (no `data-latex` attribute). The existing `renderMathInElement` text-mode auto-render covers that path; we leave it intact.

---

### Task 1: Extend `renderMath()` to re-render `<math data-latex>` elements via `katex.render`

**Files:**
- Modify: `Sources/Rubien/Views/WebReaderView.swift:1163-1185` (the `mathRendered` flag + `renderMath` function inside the reader's injected JS)

**Context:** The current `renderMath` function is wrapped in `if (mathRendered) return;` for idempotency, then in `if (typeof renderMathInElement !== 'function') return;` to bail if the auto-render script didn't load. The new code must:
- Check `katex.render` is available BEFORE attempting the data-latex pass (auto-render and `katex` are bundled separately; only `katex.js` exposes `katex.render`).
- Run the data-latex replacement BEFORE the existing auto-render call (so any LaTeX inside the `<math data-latex>` elements is removed from the DOM before auto-render walks it — prevents double-rendering on the off chance Defuddle ever emits both forms).
- Preserve the existing comment about the 4-backslash escaping for the auto-render delimiters (load-bearing for Swift triple-quote interpretation).
- Use a snapshot-and-rollback pattern for each individual `<math>` element: if `katex.render` throws for one expression, leave that `<math>` in place (browser falls back to native MathML) and continue with the rest. The whole-function try/catch wraps everything else.

**Worth knowing about the Swift string context:** the JS lives inside a Swift triple-quoted string. Swift interprets `\\` as one literal backslash before JS sees it. The new code does NOT need any backslashes (we use bracket-string selectors and dot access), so the escaping issue doesn't apply to the new lines. Only the EXISTING delimiter array (`'\\\\['`, `'\\\\]'`, `'\\\\('`, `'\\\\)'`) preserves the 4-backslash form.

- [ ] **Step 1: Read the surrounding context one more time**

```bash
sed -n '1160,1220p' Sources/Rubien/Views/WebReaderView.swift
```

Verify:
- Line 1163 is `let mathRendered = false;`
- Line 1164 is `function renderMath() {`
- Line 1185 is the closing `}` of `renderMath`
- Line 1211 is the existing `renderMath();` call from `setAnnotations`
- The 4-backslash escapes on lines 1176/1178 match what's described above

If line numbers have drifted, find the equivalent block and update the Edit's `old_string` accordingly.

- [ ] **Step 2: Replace the `renderMath` function body**

Use the Edit tool. `old_string` is the current 23-line block (lines 1163–1185 inclusive); `new_string` is the extended version below.

Current block (`old_string`):

```swift
              let mathRendered = false;
              function renderMath() {
                if (mathRendered) return;
                if (typeof renderMathInElement !== 'function') return;
                try {
                  // Delimiter escaping: this JS lives inside a Swift triple-quoted
                  // string. Swift collapses two backslashes to one before the JS
                  // engine sees the source, and JS then collapses two backslashes
                  // to one again. Hence the four backslashes here, which produce
                  // a single backslash in the runtime string KaTeX matches against.
                  renderMathInElement(article, {
                    delimiters: [
                      { left: '$$',     right: '$$',     display: true  },
                      { left: '\\\\[',  right: '\\\\]',  display: true  },
                      { left: '$',      right: '$',      display: false },
                      { left: '\\\\(',  right: '\\\\)',  display: false }
                    ],
                    throwOnError: false,
                    ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
                  });
                  mathRendered = true;
                } catch (_) {}
              }
```

Replacement (`new_string`):

```swift
              let mathRendered = false;
              function renderMath() {
                if (mathRendered) return;
                if (typeof renderMathInElement !== 'function') return;
                try {
                  // Pass 1: re-render <math data-latex="..."> elements via katex.render().
                  // Defuddle/full converts page LaTeX into MathML at extraction time,
                  // but temml drops LaTeX styling commands (\textcolor, \color, etc.)
                  // during the conversion. KaTeX's own renderer handles them, so we
                  // re-render from the preserved data-latex attribute. Per-element
                  // try/catch: a single bad expression falls back to native MathML
                  // rendering of the surviving <math>, doesn't break siblings.
                  //
                  // Annotation safety: skip any <math> that contains a wrapped
                  // annotation span (data-annotation-id). wrapRange (above) does
                  // not refuse math-internal text nodes, so an annotation CAN
                  // land inside a <math> element; replaceWith would silently
                  // drop it. Leaving such math as native MathML (colorless) is
                  // the lesser harm vs. destroying user annotations.
                  if (typeof katex !== 'undefined' && typeof katex.render === 'function') {
                    const mathNodes = article.querySelectorAll('math[data-latex]');
                    for (let i = 0; i < mathNodes.length; i++) {
                      const mathEl = mathNodes[i];
                      if (mathEl.querySelector('[data-annotation-id]')) continue;
                      const latex = mathEl.getAttribute('data-latex');
                      if (!latex) continue;
                      const displayMode = mathEl.getAttribute('display') === 'block';
                      const span = document.createElement('span');
                      try {
                        katex.render(latex, span, { displayMode: displayMode, throwOnError: false });
                        mathEl.replaceWith(span);
                      } catch (_) { /* leave <math> intact; browser falls back */ }
                    }
                  }
                  // Pass 2: legacy delimited-text path for clips whose source HTML
                  // contained `$..$` / `\(..\)` / etc. without going through Defuddle's
                  // LaTeX→MathML conversion. `ignoredClasses: ['katex']` is critical:
                  // KaTeX's output includes a hidden <annotation encoding="application/x-tex">
                  // node carrying the ORIGINAL LaTeX source for accessibility. If that
                  // source contains $, \[, \(, auto-render would recurse into it and
                  // double-render. Excluding the .katex subtree prevents that.
                  // Delimiter escaping: this JS lives inside a Swift triple-quoted
                  // string. Swift collapses two backslashes to one before the JS
                  // engine sees the source, and JS then collapses two backslashes
                  // to one again. Hence the four backslashes here, which produce
                  // a single backslash in the runtime string KaTeX matches against.
                  renderMathInElement(article, {
                    delimiters: [
                      { left: '$$',     right: '$$',     display: true  },
                      { left: '\\\\[',  right: '\\\\]',  display: true  },
                      { left: '$',      right: '$',      display: false },
                      { left: '\\\\(',  right: '\\\\)',  display: false }
                    ],
                    throwOnError: false,
                    ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code'],
                    ignoredClasses: ['katex']
                  });
                  mathRendered = true;
                } catch (_) {}
              }
```

- [ ] **Step 3: Verify Swift build**

```bash
swift build --target Rubien 2>&1 | tail -5
```

Expected: `Build of target: 'Rubien' complete!`. If the Edit didn't apply (mismatched whitespace), this will fail to compile because of broken Swift string syntax; the error will pinpoint the line.

---

### Task 2: Smoke-test against the failing URL

**Files:** (none — manual test)

- [ ] **Step 1: Launch dev build and re-clip the failing URL**

```bash
swift run Rubien
```

Then in the UI:
1. Delete reference id 1513 (the previous broken clip of `https://yumoxu.notion.site/a-gradient-level-look-at-ppo-grpo-and-cispo`) so the comparison is clean — OR add as a new clip and compare.
2. Add web clip for `https://yumoxu.notion.site/a-gradient-level-look-at-ppo-grpo-and-cispo` (5s discriminator still in place, so wait through the brief pause).
3. Open the new reference in the reader.

- [ ] **Step 2: Verify color renders**

In the reader view, look for the LaTeX expression containing `\textcolor{magenta}{r_{i,t}(\theta)}`. Pass criteria:
- The `r_{i,t}(\theta)` portion renders in magenta (or whatever color `\textcolor{}` specifies for that span)
- Other math expressions on the page render correctly (no broken layout, no raw `\command` text leaking)
- Annotation tools (highlighting, notes) still work on the rendered KaTeX output

If color is rendered → fix works. If still no color → check Console.app for `Rubien` / `OnlineReadable` logs (especially any caught exceptions) and inspect the rendered HTML via Web Inspector (right-click the reader → Inspect Element) to see whether `<math data-latex>` got replaced with `<span class="katex">` or stayed as `<math>`.

- [ ] **Step 3: Verify no regression on already-working math pages**

Re-clip one of the other math-bearing pages from the vendoring smoke set (e.g., the original `https://yumoxu.notion.site/async-grpo-in-the-wild` if reference id 1508 was math-correct, or any arXiv abstract). Open in reader. Pass criteria:
- Math still renders (no regression)
- KaTeX-rendered spans visible (right-click → Inspect → look for `<span class="katex">` instead of bare `<math>`)

- [ ] **Step 4: Verify Pass 1 + Pass 2 compose correctly (no double-rendering)**

The composition risk: KaTeX's output includes a hidden `<annotation encoding="application/x-tex">ORIGINAL_TEX</annotation>` MathML node for accessibility — that text node contains the original LaTeX source. If the source has `$`, `\[`, `\(`, etc., Pass 2's `renderMathInElement` would recurse into it and double-render. Pass 2 is configured with `ignoredClasses: ['katex']` to prevent this.

Verification: pick the math-heavy Notion clip from Step 2 (the one with `\textcolor`). Open the reader → right-click → Inspect Element on a rendered math span. Confirm:
- The math is wrapped in `<span class="katex">...</span>`
- Inside that span there is a nested `<annotation encoding="application/x-tex">` element containing the raw LaTeX source (e.g. `\textcolor{magenta}{r_{i,t}(\theta)} = \frac{...}`)
- The rendered output is NOT duplicated — only ONE visible math expression per `.katex` span
- No raw `$`, `\frac{`, etc. text leaks into the prose around the math

If you see duplicated math (e.g. one rendered expression followed by a second mangled one), the `ignoredClasses: ['katex']` setting isn't being respected — check that the bundled `auto-render.min.js` version in `Sources/Rubien/Resources/auto-render.min.js` supports the option (KaTeX auto-render added `ignoredClasses` in v0.10.0; the bundled copy is much newer).

(Note: math elements with broken LaTeX or annotation containment intentionally survive Pass 1 — they keep their `data-latex` attribute and render as native MathML. So "zero data-latex attributes in the DOM" is NOT a valid invariant; don't use that as a check.)

- [ ] **Step 5: Verify annotation safety (math element containing wrapped annotation)**

This is the Codex-flagged risk. To trigger it manually:
1. Open a math-heavy clip in the reader
2. Try to highlight (annotate) text INSIDE a math expression by click-dragging across the rendered math
3. If selection actually completes (native MathML rendering may or may not allow this), the annotation gets wrapped via `wrapRange`
4. Reload the reader → `setAnnotations` re-runs, then `renderMath` runs
5. Pass 1 should NOT replace the `<math>` element containing the annotation — verify via Inspect that the original `<math>` is preserved (not a `<span class="katex">`)

If you can't trigger an in-math annotation manually (likely — text selection inside native-MathML-rendered `<math>` is browser-dependent), this step degrades to a code-inspection check: open `Sources/Rubien/Views/WebReaderView.swift` and confirm the `if (mathEl.querySelector('[data-annotation-id]')) continue;` line is present inside the Pass-1 loop (before the `getAttribute('data-latex')` read).

---

### Task 3: Commit

**Files:** (commits the work)

- [ ] **Step 1: Inspect the diff**

```bash
git diff Sources/Rubien/Views/WebReaderView.swift
```

Expected: ~25 lines added inside the `renderMath` function. No other Swift changes.

- [ ] **Step 2: Stage and commit**

This commit assumes the vendoring commit has already landed (it should be its own preceding commit). The 5s discriminator in `Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift` stays in the working tree; it gets reverted alongside the real timing fix in a later separate commit. Stage explicitly so the working-tree discriminator isn't pulled in:

```bash
git add Sources/Rubien/Views/WebReaderView.swift docs/superpowers/plans/2026-05-23-katex-rerender-math-data-latex.md
```

Verify nothing else got picked up:

```bash
git diff --staged --stat
```

Expected: 2 files staged (`WebReaderView.swift` modified, plan doc added). NOT staged: `ReaderExtractionManager.swift`.

```bash
git commit -m "$(cat <<'EOF'
reader: re-render <math data-latex> via katex.render to restore \textcolor support

Defuddle/full converts page LaTeX into <math data-latex="...">MathML</math>
elements at extraction time, but the bundled temml library drops LaTeX
styling commands (\textcolor, \color, etc.) during MathML conversion. The
reader's existing renderMath() called KaTeX's auto-render which only walks
delimited text and ignored the <math> elements, so the browser rendered
bare colorless MathML.

Add a Pass-1 step inside renderMath() that walks article.querySelectorAll(
'math[data-latex]'), calls katex.render(latex, span, { displayMode,
throwOnError: false }) for each, and replaces the <math> with the KaTeX
output. Per-element try/catch so one bad expression falls back to native
MathML for that node only.

Annotation safety: Pass 1 skips any <math> containing a [data-annotation-id]
descendant. wrapRange does not refuse math-internal text nodes, so an
annotation can land inside a <math> element; replaceWith would silently
drop it. Leaving the affected <math> as native MathML (colorless) is
the lesser harm vs. destroying user annotations.

Composition safety: Pass 2's renderMathInElement gets `ignoredClasses:
['katex']`. KaTeX's output includes a hidden <annotation encoding="
application/x-tex">ORIGINAL_TEX</annotation> node for accessibility;
without ignoredClasses, Pass 2 would recurse into that and double-render
expressions whose source contains delimiter characters ($, \[, \().

Smoke-tested on https://yumoxu.notion.site/a-gradient-level-look-at-ppo-grpo-and-cispo
(\textcolor{magenta} renders correctly post-fix; raw text pre-fix).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Verify commit**

```bash
git log -1 --stat
```

Expected: 2 files, no co-author swap, no incidental changes.

---

## Self-Review Notes

**Spec coverage:** The plan addresses the user-reported color regression by adding a re-render step inside the existing `renderMath()` function. No scope creep — does not touch Defuddle, extraction pipeline, or the discriminator.

**Placeholder scan:** No TBDs. The replacement code block is fully written. Test step has concrete URLs and pass criteria.

**Type/identifier consistency:** `mathRendered`, `renderMathInElement`, `katex.render`, `article`, `<math data-latex>` all consistent with the existing reader JS surface (verified via grep of `WebReaderView.swift`).

**Known limitations / follow-ups not in this plan:**
- This is a downstream workaround. Upstream `temml` should support `\textcolor` natively; a future contribution to `https://github.com/ronkok/Temml` is the long-term fix.
- Performance: `querySelectorAll('math[data-latex]')` walks the article once per reader open. For articles with hundreds of math expressions the per-element `katex.render` calls dominate. Empirically Notion blog posts have dozens, not hundreds — non-issue at typical content scale.
- Idempotency: the outer `if (mathRendered) return;` flag prevents re-entry, so per-element idempotency inside Pass 1 is not load-bearing. (Codex flagged the original self-review claim as overstated; corrected.)
- Annotation-in-math defense: Pass 1's `[data-annotation-id]` containment guard is a tactical safety net. The structural fix is in `wrapRange` — refuse text nodes whose `parentElement.closest('math')` is non-null. That's a wider change to the annotation system; deferred as a follow-up. Until then, annotations placed inside `<math>` survive but render with native MathML (no `\textcolor`).
- `\color` / `\colorbox` (alternate LaTeX color syntax). KaTeX supports both, and Pass 1 calls KaTeX on the raw LaTeX source, so they should work transparently. Not explicitly smoke-tested because Notion's editor emits `\textcolor` as the canonical form; flag if a real-world clip surfaces either alternate form unrendered.
