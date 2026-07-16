# Vendor Defuddle as a Direct Dependency (`scripts/clipper/`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop depending on the external `obsidian-clipper` project for our bundled Defuddle JavaScript. Set up `scripts/clipper/` mirroring the existing `scripts/note-editor/` pattern: a small Node sub-project with `defuddle@^0.18.1` as a direct npm dependency, an esbuild driver that produces `Sources/Rubien/Resources/ClipperDefuddle.js`, and a thin wrapper exposing `window.RubienDefuddleExtract()` to keep the Swift-side `ReaderExtractionManager` contract stable.

**Architecture:** New sub-project at `scripts/clipper/` owns the JS toolchain. Its `package.json` pins `defuddle` (currently `^0.18.1`) as a regular dependency and `esbuild` as a devDependency. `build.mjs` runs esbuild in IIFE mode targeting Safari 17 with a single entry point (`src/clipper-defuddle.js`) and writes the minified bundle directly over the existing `Sources/Rubien/Resources/ClipperDefuddle.js`. The wrapper imports `defuddle/full` (math + markdown support), runs `new Defuddle(document).parse()`, normalizes the result into the existing message shape (`{ source, ok, content, title, description, excerpt, author }`), and posts via both channels the Swift side already uses: `webkit.messageHandlers.readerResult.postMessage(payload)` *and* a `JSON.stringify(payload)` return value (`evaluateJavaScript` returns this string to `processDefuddleJSONFallback`).

**Tech Stack:** Node ≥ 20, esbuild 0.25, defuddle 0.18.1. No new Swift code — this PR only adds Node tooling and regenerates one resource file.

**Scope boundaries (NOT in this plan):**
- The temporary 5s discriminator in `ReaderExtractionManager.runOnlineArticleExtraction` stays in place across this work, gets reverted in a *separate* follow-up commit alongside the real timing fix (substantive-content guard + retry chain). Mixing them here would conflate two roots of behavior change.
- The `ClipperReader.css` / `ClipperHighlighter.css` files (from obsidian-clipper) stay as-is. They are reader *styling*, separate from extraction; vendoring them is a future task.
- Notion-specific code-block normalization is a *separate* plan if the Defuddle upgrade doesn't fix it (the changelog confirms no Notion extractor exists in 0.17/0.18, so we should assume it won't).

**Risk surface:** Defuddle is the primary extraction path for *every* web clip. A bad upgrade could regress sites that currently work. Mandatory smoke test set (Task 7) gates the commit.

---

### Task 1: Scaffold `scripts/clipper/` directory + package.json

**Files:**
- Create: `scripts/clipper/package.json`
- Create: `scripts/clipper/.gitignore`

- [ ] **Step 1: Create directory and write `package.json`**

```bash
mkdir -p /Users/hzzheng/CodeHub/Rubien/scripts/clipper/src
```

Then write `scripts/clipper/package.json`:

```json
{
  "name": "rubien-clipper",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "node build.mjs"
  },
  "dependencies": {
    "defuddle": "^0.18.1"
  },
  "devDependencies": {
    "esbuild": "^0.25.0"
  }
}
```

Notes:
- `"type": "module"` is required so the ESM `import Defuddle from 'defuddle/full'` works in `build.mjs` and in `src/clipper-defuddle.js` source.
- `"private": true` prevents accidental publishing.
- `defuddle` is a regular dependency (shipped artifact ends up in the Swift bundle), `esbuild` is dev-only (build-time tool).

- [ ] **Step 2: Write `.gitignore` to exclude `node_modules/`**

Write `scripts/clipper/.gitignore`:

```
node_modules/
```

`package-lock.json` is NOT ignored — it gets committed so the version pin is reproducible.

- [ ] **Step 3: Verify scaffolding**

Run:
```bash
ls /Users/hzzheng/CodeHub/Rubien/scripts/clipper/
```

Expected output (alphabetical):
```
.gitignore
package.json
src
```

---

### Task 2: Write the JS wrapper `src/clipper-defuddle.js`

**Files:**
- Create: `scripts/clipper/src/clipper-defuddle.js`

**Why this wrapper exists:** Defuddle's API returns a result object directly from `new Defuddle(document).parse()` (sync) or `inst.parseAsync()` (async, if exposed). The existing Swift code (`ReaderExtractionManager.userContentController` and `processDefuddleJSONFallback`) expects:
- A function named `RubienDefuddleExtract` callable from `evaluateJavaScript`
- That function posts a message via `webkit.messageHandlers.readerResult` (the canonical delivery channel). For the sync path it ALSO returns a JSON string from `evaluateJavaScript` (dual channel — Swift's `processDefuddleJSONFallback` reads it as a 0.2s safety net if postMessage hasn't arrived).
- Message body has shape `{ source: "defuddle", ok: bool, content: string, title?: string, description?: string, excerpt?: string, author?: string }`
- `source: "defuddle"` is checked in `userContentController` (line 60-61) to distinguish from other channels

**Two more contracts** that the previous bundle honored and the new wrapper must preserve (confirmed against the current minified bundle and against `Sources/Rubien/Views/WebReaderView.swift:1725` + `:1997`):

- **`parseAsync` with 45 s timeout:** the current bundle calls `parseAsync({url: document.URL})` wrapped in a 45-second timeout. This protects against pathological pages where Defuddle hangs (since sync `.parse()` can't be canceled — JS sync execution blocks the worker thread). The new wrapper must preserve this if `parseAsync` exists in Defuddle 0.18.1; if it doesn't, the wrapper falls back to sync `.parse()` and the timeout is dropped (documented loss).
- **`RubienClipperDebug` channel:** Swift registers `RubienClipperDebug` as a script message handler at `WebReaderView.swift:1725` and logs `{phase, url, detail}` bodies at `:1997-2002`. The current bundle posts four phase names: `rubien_defuddle_extract_start`, `rubien_defuddle_parse_async_begin`, `rubien_defuddle_parse_async_end`, `rubien_defuddle_exit`. The new wrapper must keep posting these — they're load-bearing diagnostics for the OnlineReadable category and feed `os_log`.

This wrapper bridges all three shapes.

- [ ] **Step 1: Write the wrapper file**

Write `scripts/clipper/src/clipper-defuddle.js`:

```javascript
// Bridges Defuddle's parse() / parseAsync() result to the JSON contract
// that Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift expects,
// and preserves the RubienClipperDebug diagnostic channel that
// Sources/Rubien/Views/WebReaderView.swift:1725 (registration) and
// :1997 (consumer) rely on.
//
// Two delivery channels for the result:
//   1. webkit.messageHandlers.readerResult.postMessage(payload)  — canonical
//   2. return JSON.stringify(payload)                            — sync-only fallback
// The Swift side de-duplicates via `defuddleResultHandled`. For the async
// (parseAsync) path the return value is `undefined`, matching the
// previous bundle's behavior — postMessage is the only practical channel
// when extraction is async.
//
// We import defuddle/full (not core) so MathML and Markdown helpers are
// available — current Rubien content (e.g. ML/RL blog posts with KaTeX)
// relies on math preservation.

import Defuddle from 'defuddle/full';

// Matches the timeout the previous obsidian-clipper bundle enforced.
// Only effective on the parseAsync path; sync `.parse()` can't be canceled.
const PARSE_TIMEOUT_MS = 45_000;

function debugPost(phase, detail) {
  try {
    const ch =
      typeof window !== 'undefined' &&
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.RubienClipperDebug;
    if (!ch) return;
    ch.postMessage({
      phase,
      url: (typeof document !== 'undefined' && document.URL) || '',
      detail: detail == null ? '' : String(detail),
    });
  } catch (_) {
    // Debug channel failures are non-fatal.
  }
}

function buildPayload(result, error) {
  if (error) {
    return {
      source: 'defuddle',
      ok: false,
      error: String(error && error.message ? error.message : error),
    };
  }
  const content = (result && result.content) ? result.content : '';
  const hasContent = content.trim().length > 0;
  return {
    source: 'defuddle',
    ok: hasContent,
    content,
    title: (result && result.title) || '',
    description: (result && result.description) || '',
    // `excerpt` is a legacy alias the Swift side falls back to when
    // `description` is absent. Defuddle 0.18.1 doesn't emit a separate
    // excerpt field, so we mirror description here.
    excerpt: (result && result.description) || '',
    author: (result && result.author) || '',
  };
}

function postResult(payload) {
  try {
    if (
      typeof window !== 'undefined' &&
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.readerResult
    ) {
      window.webkit.messageHandlers.readerResult.postMessage(payload);
    }
  } catch (_) {
    // postMessage failure is non-fatal — sync path falls back to the
    // JSON return value.
  }
  return JSON.stringify(payload);
}

window.RubienDefuddleExtract = function RubienDefuddleExtract() {
  // Defense-in-depth: Promise.race below settles exactly once per spec,
  // so under correct semantics `deliver` is called once. This guard
  // protects against (a) the IIFE script being injected twice for the
  // same page, (b) future edits accidentally introducing a real race,
  // (c) any WKScriptMessageHandler quirk that delivers a message twice.
  // Mirrors the Swift side's `defuddleResultHandled` flag — belt and
  // suspenders.
  let delivered = false;
  function deliver(payload) {
    if (delivered) return JSON.stringify(payload);
    delivered = true;
    return postResult(payload);
  }

  debugPost('rubien_defuddle_extract_start');
  let inst;
  try {
    inst = new Defuddle(document, { url: document.URL });
  } catch (err) {
    debugPost('rubien_defuddle_exit', 'ctor_error: ' + (err && err.message));
    return deliver(buildPayload(null, err));
  }

  if (typeof inst.parseAsync === 'function') {
    // Async path: postMessage is the only practical delivery channel.
    // evaluateJavaScript will see `undefined` as the return value;
    // Swift's processDefuddleJSONFallback (0.2 s after evaluateJavaScript's
    // callback) checks `defuddleResultHandled` first, so it only triggers
    // if postMessage hasn't landed yet — typical extraction finishes in
    // well under 200 ms, so postMessage almost always wins the race.
    debugPost('rubien_defuddle_parse_async_begin');
    const timeout = new Promise((_, reject) =>
      setTimeout(
        () => reject(new Error('parse_timeout_' + PARSE_TIMEOUT_MS + 'ms')),
        PARSE_TIMEOUT_MS
      )
    );
    Promise.race([inst.parseAsync(), timeout])
      .then((result) => {
        debugPost('rubien_defuddle_parse_async_end');
        const payload = buildPayload(result, null);
        debugPost('rubien_defuddle_exit', 'ok=' + payload.ok);
        deliver(payload);
      })
      .catch((err) => {
        debugPost('rubien_defuddle_exit', 'error: ' + (err && err.message));
        deliver(buildPayload(null, err));
      });
    return undefined;
  }

  // Sync path: both channels carry the same payload.
  try {
    const result = inst.parse();
    const payload = buildPayload(result, null);
    debugPost('rubien_defuddle_exit', 'ok=' + payload.ok);
    return deliver(payload);
  } catch (err) {
    debugPost('rubien_defuddle_exit', 'error: ' + (err && err.message));
    return deliver(buildPayload(null, err));
  }
};
```

Notes:
- Assigning to `window.RubienDefuddleExtract` (not `var`/`const`) is required because esbuild's IIFE format scopes top-level declarations to the IIFE; only explicit `window.X = ...` survives to global scope where `evaluateJavaScript("RubienDefuddleExtract()")` can reach it (`scripts/note-editor/src/editor.js` uses the same `window.NoteEditor = ...` pattern, confirmed reachable bare from Swift).
- We pass `{ url: document.URL }` to the Defuddle constructor because the previous bundle did — Defuddle's site-specific extractors use the URL to choose a matcher.
- We want HTML content (the default), NOT markdown. The Swift code expects HTML — `augmentContentWithCoverImageIfMissing` runs regex over `<img>` tags.
- **Asymmetry between sync and async paths is deliberate.** The previous bundle was async-only; the new wrapper falls back to sync if `parseAsync` is gone in 0.18.1 (Task 4 Step 3 verifies which we got). Sync path loses the 45 s timeout protection because JS can't cancel sync execution mid-run, but reactivates the JSON-return fallback channel that async can't use.

- [ ] **Step 2: Lint check the wrapper is valid JS**

Run from `/Users/hzzheng/CodeHub/Rubien/scripts/clipper/`:
```bash
node --check src/clipper-defuddle.js
```

Expected: no output, exit 0. The sub-project's `package.json` has `"type": "module"` (Task 1), so node treats the `.js` file as ESM and the top-level `import` statement parses cleanly. (`scripts/note-editor/` uses the same pattern and `node --check src/editor.js` passes there.)

---

### Task 3: Write `build.mjs` (esbuild driver)

**Files:**
- Create: `scripts/clipper/build.mjs`

- [ ] **Step 1: Write the build script**

Write `scripts/clipper/build.mjs`:

```javascript
// Bundles src/clipper-defuddle.js (which imports defuddle/full) into a
// single IIFE-wrapped script that WKWebView can load via
// evaluateJavaScript. Output overwrites Sources/Rubien/Resources/ClipperDefuddle.js.
//
// To upgrade Defuddle:
//   1. cd scripts/clipper && npm update defuddle
//   2. npm run build
//   3. Commit package.json, package-lock.json, and the regenerated
//      Sources/Rubien/Resources/ClipperDefuddle.js together.

import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const outfile = resolve(here, '../../Sources/Rubien/Resources/ClipperDefuddle.js');

await build({
  entryPoints: [resolve(here, 'src/clipper-defuddle.js')],
  bundle: true,
  format: 'iife',
  // WKWebView on macOS 15 Sequoia is Safari 17-class. Target this
  // explicitly so esbuild doesn't downlevel modern syntax unnecessarily.
  target: 'safari17',
  minify: true,
  outfile,
  // Banner makes the file's purpose obvious when someone opens the raw
  // resource file in the Swift package.
  banner: {
    js: '/* Rubien clipper-defuddle bundle. Built from scripts/clipper/ — do not edit by hand. */',
  },
  logLevel: 'info',
});

console.log(`Wrote ${outfile}`);
```

- [ ] **Step 2: Verify the script file is syntactically valid**

Run from `/Users/hzzheng/CodeHub/Rubien/scripts/clipper/`:
```bash
node --check build.mjs
```

Expected: no output, exit 0.

---

### Task 4: Install dependencies and produce first build

**Files:**
- Modify (regenerate): `Sources/Rubien/Resources/ClipperDefuddle.js`
- Create: `scripts/clipper/package-lock.json` (npm-generated)

- [ ] **Step 1: Run npm install**

From `/Users/hzzheng/CodeHub/Rubien/scripts/clipper/`:
```bash
npm install
```

Expected: completes without errors. Creates `node_modules/` (gitignored) and `package-lock.json` (committed). Should report `added N packages` where N is small (defuddle has minimal dependencies — see Task 4 verification).

- [ ] **Step 2: Confirm Defuddle version pinned**

Run from `/Users/hzzheng/CodeHub/Rubien/scripts/clipper/`:
```bash
cat node_modules/defuddle/package.json | grep '"version"'
```

Expected: `"version": "0.18.1"` (or newer if a patch shipped after this plan was written).

- [ ] **Step 3: Verify Defuddle 0.18.1 API surface (parseAsync, full entry point, exports map)**

The wrapper in Task 2 supports both `parseAsync` (async, with 45 s timeout) and sync `.parse()` paths. This step confirms which one we actually get from 0.18.1, plus that `defuddle/full` resolves cleanly to a browser-bundleable entry. Run from `/Users/hzzheng/CodeHub/Rubien/scripts/clipper/`:

```bash
# What's in the exports map? (Confirms ./full is a real entry point.)
node -e "console.log(JSON.stringify(require('./node_modules/defuddle/package.json').exports, null, 2))"

# Does the browser API expose parseAsync? Inspect the type declarations.
grep -nE "parseAsync|^\s*parse\(|class Defuddle" node_modules/defuddle/dist/index.d.ts node_modules/defuddle/dist/full.d.ts 2>/dev/null | head -20
```

Three possible outcomes:
- **parseAsync exists on the Defuddle class** → the wrapper takes the async branch in production. Timeout protection active. This is the preferred outcome.
- **Only sync `.parse()` is exposed** → the wrapper takes the sync branch. No timeout protection (acknowledged in Task 2 notes). Acceptable but worth noting in the commit message.
- **`defuddle/full` doesn't exist or fails to resolve** → fall back to `defuddle` (core). Edit `src/clipper-defuddle.js` to change `from 'defuddle/full'` to `from 'defuddle'`, rebuild, accept the loss of bundled math/markdown helpers (likely OK — MathML inside the source DOM is preserved by Defuddle's generic walker regardless of the `/full` entry; the `/full` helpers are mainly for *generating* math output, not preserving it).

Record which outcome applies in the eventual commit message (Task 8 Step 4) under a "Defuddle 0.18.1 API notes" line so future maintainers know.

- [ ] **Step 4: Run the build**

From `/Users/hzzheng/CodeHub/Rubien/scripts/clipper/`:
```bash
npm run build
```

Expected:
- esbuild prints a summary line like `dist  Sources/Rubien/Resources/ClipperDefuddle.js  XXXkb` (likely 200–400 KB, smaller than the current 587 KB obsidian-clipper bundle).
- Final line: `Wrote /Users/hzzheng/CodeHub/Rubien/Sources/Rubien/Resources/ClipperDefuddle.js`.

- [ ] **Step 5: Sanity-check the produced bundle**

```bash
ls -la /Users/hzzheng/CodeHub/Rubien/Sources/Rubien/Resources/ClipperDefuddle.js
head -c 200 /Users/hzzheng/CodeHub/Rubien/Sources/Rubien/Resources/ClipperDefuddle.js
```

Expected:
- File exists, size > 50 KB and < 600 KB.
- First line starts with the banner: `/* Rubien clipper-defuddle bundle. Built from scripts/clipper/ — do not edit by hand. */`
- Second line begins with `(()=>{` (esbuild IIFE prefix).

If the file is much larger than 600 KB, something is wrong — investigate (probably accidentally bundled `defuddle/node` or pulled in test fixtures).

---

### Task 5: Verify Swift build still resolves the bundle

**Files:** (none modified — verification step)

- [ ] **Step 1: Build the Rubien target**

From `/Users/hzzheng/CodeHub/Rubien/`:
```bash
swift build --target Rubien 2>&1 | tail -10
```

Expected: `Build of target: 'Rubien' complete!` with no errors. The new `ClipperDefuddle.js` is loaded as `Bundle.module` resource — Swift doesn't parse the JS, it just needs the file to be present and copied into the bundle.

If this fails with a "resource not found" type error, the new bundle is missing from `Package.swift`'s resource list. Check `Package.swift` for `Sources/Rubien/Resources/ClipperDefuddle.js` (it should already be picked up by an existing `process` or `copy` directive — the rename to obsidian-clipper-free didn't change the filename).

---

### Task 6: Update `CLIPPER_BUNDLE.txt` to reflect the new build flow

**Files:**
- Modify: `Sources/Rubien/Resources/CLIPPER_BUNDLE.txt`

- [ ] **Step 1: Rewrite the file**

The current file references `obsidian-clipper/` as the external source. After this plan lands, the build lives in this repo at `scripts/clipper/`. Update the file to match.

Replace the entire contents of `/Users/hzzheng/CodeHub/Rubien/Sources/Rubien/Resources/CLIPPER_BUNDLE.txt` with:

```
Rubien — bundled web-clipper extraction assets
==============================================

Files in this directory:
- ClipperDefuddle.js     — esbuild bundle of `defuddle/full` + RubienDefuddleExtract wrapper.
                           Built by scripts/clipper/ in this repo (NOT from obsidian-clipper anymore).
- ClipperReader.css      — copied from obsidian-clipper/dist/reader.css (still vendored from upstream).
- ClipperHighlighter.css — copied from obsidian-clipper/dist/highlighter.css (still vendored from upstream).
- Readability.js         — Mozilla Readability (Apache-2.0), fallback extractor.

Contract (ClipperDefuddle.js ↔ ReaderExtractionManager.swift, WebReaderView.swift):
- Defines `window.RubienDefuddleExtract()`.
- Called via `evaluateJavaScript("RubienDefuddleExtract()")` from
  ReaderExtractionManager.injectAndRunDefuddle().
- Dual-channel result delivery:
    1. webkit.messageHandlers.readerResult.postMessage(payload)   — canonical, always used.
    2. return JSON.stringify(payload)                              — sync-path fallback only;
       async (parseAsync) path returns undefined.
  Payload shape: `{ source: "defuddle", ok, content, title, description, excerpt, author }`.
  The Swift side de-duplicates with `defuddleResultHandled`.
  `source` MUST be the literal string `"defuddle"` — userContentController filters on it.
- Diagnostic channel: webkit.messageHandlers.RubienClipperDebug carries
  `{ phase, url, detail }` for the online-read pipeline. Phases emitted:
  `rubien_defuddle_extract_start`, `rubien_defuddle_parse_async_begin`,
  `rubien_defuddle_parse_async_end`, `rubien_defuddle_exit`.
  Registered on the WKWebView in WebReaderView.swift (look for
  `RubienClipperDebug` in that file); consumed by the same Coordinator's
  userContentController switch. Logs to subsystem `Rubien`, category
  `OnlineReadable`.

To update Defuddle:
  cd scripts/clipper/
  npm update defuddle    # or: npm install defuddle@<version>
  npm run build
  # commit scripts/clipper/package.json, package-lock.json,
  # and the regenerated Sources/Rubien/Resources/ClipperDefuddle.js together.

To update the reader stylesheets (separate concern — still upstream obsidian-clipper):
  Copy obsidian-clipper/dist/reader.css → ClipperReader.css
  Copy obsidian-clipper/dist/highlighter.css → ClipperHighlighter.css

Debugging the online-read pipeline: open Console.app → filter subsystem `Rubien`,
category `OnlineReadable`. You should see entries like
`[JS] rubien_defuddle_extract_start url=https://… ` etc.

Licenses: Defuddle is MIT (see scripts/clipper/node_modules/defuddle/LICENSE).
Readability.js is Apache-2.0. Clipper stylesheets retain their Obsidian/upstream copyright.
```

Notes on what changed:
- Removed the obsidian-clipper / `npm run build:rubien-defuddle` reference (no longer how we build).
- Documented the `RubienClipperDebug` channel explicitly — it IS load-bearing (registered at `Sources/Rubien/Views/WebReaderView.swift:1725`, consumed at `:1997`) and the new wrapper preserves it.
- Documented sync vs async return-value asymmetry so future Defuddle upgrades don't accidentally regress the JSON-fallback contract.
- Explicit contract section so future Defuddle upgrades know what the wrapper has to preserve.

---

### Task 7: Smoke test against the regression set

**Files:** (none — manual test step)

**Why this gates commit:** Defuddle is the primary extraction path. We need confidence that the upgrade hasn't broken sites that currently work, *before* committing.

- [ ] **Step 1: Launch the dev build**

From `/Users/hzzheng/CodeHub/Rubien/`:
```bash
swift run Rubien
```

(Not `dev-launch.sh` — we don't need entitlements for clipping, and `swift run` is faster.)

- [ ] **Step 2: Clip each URL in the smoke set; record the outcome**

For each URL below, click Rubien's "Add → Web clip" (or whatever the UI calls it) and observe:
- Does extraction complete (no error toast)?
- Is the title correct (matches the page's actual title, not a generic "Welcome" or marketing fallback)?
- Is the body content the actual article (not a stub / not the marketing site fallback)?
- Are code blocks rendered (where applicable)?

Smoke set. The first six URLs cover broad shapes; URLs 7–10 specifically exercise the changes called out in the Defuddle 0.17.0 → 0.18.1 changelog (Wikipedia footnotes, anchor-linked headings, Discourse, footnote/sidenote refactor) so a regression there is visible *here* and not in user clips:

1. **The bug URL** — `https://yumoxu.notion.site/async-grpo-in-the-wild`
   - Expected with current 5s discriminator still in place: title "Async GRPO in the Wild" and the actual post body. Note whether code blocks render now or still come out as plain inline spans (Defuddle 0.18.x doesn't have a Notion extractor per the changelog, so likely still broken — but we want to confirm).
2. **A standard blog post** — pick any post from `https://lilianweng.github.io/` (e.g. the most recent one). Should extract cleanly with prose, headings, footnotes.
3. **A Substack post** — pick any free public post.
4. **A Medium post** — Defuddle 0.18.0 added a Medium extractor; should work well.
5. **An arXiv abstract page** — e.g. `https://arxiv.org/abs/1706.03762`. Should extract title + abstract.
6. **A plain news article** — pick anything from a major news site you have access to.
7. **Wikipedia article with footnotes** — `https://en.wikipedia.org/wiki/PageRank` (heavy footnote usage). Specifically exercises Defuddle 0.18.1's "Fix Wikipedia footnotes" change. Expected: footnotes survive the extraction; numbered references in the body link to the references section without losing anchors.
8. **Article with anchor-linked headings** — any MDN reference page works, e.g. `https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array`. Exercises 0.18.1's "legitimate link with anchor being removed in headings" fix. Expected: heading anchors (`#methods`, `#instance_properties`, etc.) preserved as clickable links inside the extracted body.
9. **A Discourse forum thread** — pick any thread from `https://discourse.julialang.org/latest` or `https://meta.discourse.org/`. 0.18.0 added a Discourse extractor; this verifies it activates and produces sensible output (single OP body, reply ordering, no nav chrome).
10. **A page with sidenotes / footnote-heavy structure** — `https://gwern.net/` (any essay; their sidenotes are a stress test for the 0.18.0 footnote/sidenote refactor). Expected: footnote markers in prose are preserved and resolve to the sidenote/footnote text; no markers left dangling.

- [ ] **Step 3: Record results**

Write a short summary somewhere (commit message draft is fine):
- For each URL: PASS / FAIL / DEGRADED + one-line note.
- Acceptance threshold: zero hard regressions on URLs 2–10 (sites or page shapes that work today *must* still work). URL 1 (Notion) is informational — we know Defuddle has no Notion extractor; we're checking how the generic path handles it.

- [ ] **Step 4: If any of URLs 2–10 regressed**

STOP. Do not commit. Diagnose:
- Check Console.app for `Rubien` / `OnlineReadable` log entries — `readerResult defuddle ok=false → Readability` indicates Defuddle gave up; `Defuddle succeeded contentLength=N` shows it ran.
- If a previously-working site now fails, the new Defuddle has a regression for that site type. Options:
  a. Pin to an older Defuddle version that worked (the whole point of vendoring: change `^0.18.1` → e.g. `0.17.0` in `scripts/clipper/package.json`, `npm install`, `npm run build`, re-test).
  b. File an upstream issue at github.com/kepano/defuddle and stay on the older version while it's resolved.

---

### Task 8: Commit

**Files:** (commits the work)

- [ ] **Step 1: Inspect what changed**

```bash
git status
git diff --stat
```

Expected new/modified files:
- `scripts/clipper/.gitignore` (new)
- `scripts/clipper/package.json` (new)
- `scripts/clipper/package-lock.json` (new)
- `scripts/clipper/build.mjs` (new)
- `scripts/clipper/src/clipper-defuddle.js` (new)
- `Sources/Rubien/Resources/ClipperDefuddle.js` (modified — regenerated)
- `Sources/Rubien/Resources/CLIPPER_BUNDLE.txt` (modified — rewritten)

Expected NOT modified:
- Any Swift file (the temporary discriminator in `ReaderExtractionManager.swift` stays in place; it gets reverted in the separate timing-fix commit).
- `Package.swift` (the resource glob already covers the regenerated file).

- [ ] **Step 2: Stage the files explicitly (no `git add -A`)**

```bash
git add scripts/clipper/.gitignore \
        scripts/clipper/package.json \
        scripts/clipper/package-lock.json \
        scripts/clipper/build.mjs \
        scripts/clipper/src/clipper-defuddle.js \
        Sources/Rubien/Resources/ClipperDefuddle.js \
        Sources/Rubien/Resources/CLIPPER_BUNDLE.txt
```

- [ ] **Step 3: Verify staged set matches expectations**

```bash
git diff --staged --stat
```

Confirm 7 files staged. No surprises.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
chore: vendor Defuddle 0.18.1 via scripts/clipper/

Replaces the externally-built ClipperDefuddle.js (previously built from
the obsidian-clipper sibling project) with an in-repo build pipeline at
scripts/clipper/, mirroring the existing scripts/note-editor/ pattern.
Defuddle is now a pinned npm dependency, visible in package.json and
upgradeable with `npm update defuddle && npm run build`.

The bundled artifact at Sources/Rubien/Resources/ClipperDefuddle.js is
regenerated; the wrapper preserves the existing `RubienDefuddleExtract()`
contract (dual-channel postMessage + JSON return) so no Swift changes are
needed. CLIPPER_BUNDLE.txt updated to reflect the new build flow.

Smoke-tested against: [paste the per-URL results from Task 7].

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Verify commit landed**

```bash
git log -1 --stat
```

Expected: single commit with the 7 files. No co-author swap, no unintended files.

---

## Self-Review Notes

**Spec coverage check:** All four scope elements addressed — new sub-project (Task 1), npm-installable dependency (Tasks 1+4), in-repo build script (Task 3), pinned-and-visible version (Task 4). The wrapper's contract preservation is explicit in Task 2's "Why this wrapper exists" + the rewritten CLIPPER_BUNDLE.txt in Task 6.

**Placeholder scan:** No TBDs, no "implement appropriate handling," no unspecified types. Smoke test URLs are concrete; commit message is filled in with a placeholder only for the per-URL results (which can only be filled in after the smoke test actually runs).

**Type consistency:** Wrapper function name `RubienDefuddleExtract` consistent between Task 2 (definition), Task 6 (docs), and the existing Swift call site at `ReaderExtractionManager.swift:129`. Message body fields (`source`, `ok`, `content`, `title`, `description`, `excerpt`, `author`) match what `userContentController` reads (lines 57-83 of ReaderExtractionManager.swift).

**Known limitations / follow-ups not in this plan:**
- Discriminator (5s upfront wait) stays in place; reverted in the timing-fix follow-up.
- Notion code-block normalization is a separate plan — Defuddle 0.17/0.18 changelog confirms no Notion extractor, so even with this upgrade Notion code blocks likely remain stripped.
- No automated tests for extraction quality. Adding the `rubien-cli web add` subcommand (discussed in conversation) would make Defuddle upgrades regression-testable in CI. Future task.
