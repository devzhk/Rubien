# Unified Notion Per-Host Extractor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three piecemeal Notion DOM normalizers (`normalizeNotionCodeBlocks`, `normalizeNotionLists`, `normalizeNotionInlineCode`) in `scripts/clipper/src/clipper-defuddle.js` with a single unified `extractNotionPage(doc)` function that walks Notion's `[data-block-id]` tree top-to-bottom and emits clean semantic HTML for every block type. This stops the whack-a-mole pattern (each piecemeal normalizer risks regressing another shape — we just hit that with the inline-code change breaking math) and gives us complete, predictable extraction for Notion content.

**Architecture:** Per-host extractor pattern, matching the model Defuddle's existing extractors (LinkedIn, Threads, Bluesky, Discourse, Medium) follow. On Notion hosts only, the wrapper:
1. Clones `document` (same approach the current code uses — avoids React reconciliation).
2. Runs the unified extractor on the clone. The extractor walks the page's main content container, dispatches each `[data-block-id]` element to a per-class handler, and produces `{ content: string, title: string|null }`.
3. Runs Defuddle on the clone for metadata extraction (description, author, image, language). Defuddle's metadata pipeline is robust; we keep using it for those fields.
4. Override Defuddle's `title` if `extractNotionPage` returned one (Notion's `<title>` is always literally "Notion", so Defuddle's title is wrong for Notion clips by default — we replace with the real page title from `notion-page-block`).
5. Override Defuddle's `content` with the unified extractor's HTML.

For non-Notion hosts, the flow is unchanged: Defuddle runs end-to-end and we use its output as-is.

**Tech Stack:** Pure JS in `scripts/clipper/src/clipper-defuddle.js`. No new npm dependencies. Reuses the existing `scripts/clipper-test/verify-extraction.mjs` Playwright harness for end-to-end verification.

**Scope boundaries (NOT in this plan):**
- **Upstream Defuddle PR.** The user wants this eventually contributed back to `github.com/kepano/defuddle` so it benefits everyone. That requires studying Defuddle's extractor API conventions (their existing per-host extractors live in `node_modules/defuddle/dist/extractors/`), conforming to their interface, writing tests in their style, and submitting a PR. Separate plan, separate timeline. This plan ships the local implementation first.
- **Speculative handlers for unobserved block types.** `notion-to_do-block`, `notion-bookmark-block`, `notion-video-block`, `notion-audio-block`, `notion-file-block`, `notion-synced_block` were NOT seen on any of the three probed pages. They get text-preserving fallback via `extractDefault`; dedicated handlers added when we hit them in production.
- **Reverting the discriminator.** 5s wait in `Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift` stays in the working tree; reverted in its own follow-up alongside the real timing fix.

**In scope (added 2026-05-23 after Task 1 probes completed):**
- **Toggle blocks** (`notion-toggle-block`). Probe finding: children are NOT in the DOM when collapsed — React lazy-renders them on expand. Handler strategy: iteratively pre-expand all collapsed toggles in the LIVE document (`button.click()` on the toggle's own `[aria-expanded="false"][role="button"]`) with 500ms-per-pass + two-consecutive-empty-passes confirmation (handles nested lazy toggles where clicking a parent reveals more collapsed children), THEN clone, THEN extract. After expansion the children are normal `[data-block-id]` descendants of the toggle block. Rendered as `<details open><summary>{label}</summary>{children}</details>`. Worst case ~5s on pathologically nested pages; typical Notion docs finish in 1-2 passes (<1.5s).
- **Callout blocks** (`notion-callout-block`). Rendered as `<aside class="rubien-notion-callout">{icon-text} {body}</aside>`. Icon is whatever Notion put in the icon span (emoji or empty).
- **Quote blocks** (`notion-quote-block`). Rendered as `<blockquote>{inline-content}</blockquote>`.
- **Column layout** (`notion-column_list-block` containing `notion-column-block` children). Rendered as a sequence of column contents stacked vertically (readers don't have horizontal real estate); no wrapping element. Column children are walked as normal top-level blocks.
- **Embed blocks** (`notion-embed-block`, `notion-bookmark-block` if seen). Rendered as `<div class="rubien-notion-embed">[Embed: <a href="$src">$src</a>]</div>` so users know something was there. Iframe src extracted from descendant `<iframe>`; falls back to a generic placeholder if no src.

**Sequencing:** This commit replaces the 3 piecemeal normalizers with one extractor. The piecemeal-normalizer working tree state is NOT preserved as its own commit — the unified extractor is the durable artifact; the experimental piecemeal approach taught us the shapes Notion uses, and that knowledge is now codified in the extractor.

---

### Task 1: Probe Notion's block + inline shapes (COMPLETE 2026-05-23)

**Files:**
- `scripts/clipper-test/diagnose-notion-inventory.mjs` (block-class inventory)
- `scripts/clipper-test/diagnose-notion-inline.mjs` (inline shapes + nested-list probe)
- `scripts/clipper-test/diagnose-notion-novel.mjs` (sample outerHTML for unhandled block types)
- `scripts/clipper-test/diagnose-notion-toggle.mjs` (collapsed-vs-expanded toggle probe)

Findings, distilled from probes across `yumoxu.notion.site/async-grpo-in-the-wild`, `yumoxu.notion.site/a-gradient-level-look-at-ppo-grpo-and-cispo`, and `yaofu.notion.site/Full-Stack-Transformer-Inference-Optimization-Season-2-Deploying-Long-Context-Models`:

**Block inventory (19 distinct class signatures across the three pages):**
- `notion-page-block` (title; always present)
- `notion-text-block` (paragraph)
- `notion-header-block` / `notion-sub_header-block` / `notion-sub_sub_header-block` (h2/h3/h4)
- `notion-bulleted_list-block` / `notion-numbered_list-block` (flat siblings — see nested-list finding below)
- `notion-code-block` (with `notion-selectable` sibling class)
- `notion-equation-block` (block math)
- `notion-image-block`
- `notion-table-block`
- `notion-table_of_contents-block`
- `notion-divider-block`
- `notion-toggle-block` (lazy children — see toggle finding below)
- `notion-callout-block`
- `notion-quote-block`
- `notion-column_list-block` (wrapper) + `notion-column-block` (children)
- `notion-embed-block`

**Nested-list finding:** Sub-items in bulleted/numbered lists are FLAT SIBLINGS at the top level with CSS-only indentation. `notion-bulleted_list-block` elements have ZERO `[data-block-id]` descendants. Implication: the list handler stays flat (no recursive walk needed), and the existing grouping logic in the dispatcher is correct.

**Toggle finding (decision: pre-expand in live document):** Probe showed collapsed toggles have 0 child `[data-block-id]` descendants (outerHTML 2013 chars). After `button.click()` on the `[aria-expanded="false"]` disclosure button and a 2-second wait, the same toggle's outerHTML grew to 3350 chars and contained the child block (a nested `notion-code-block` in the test case). React lazy-renders children only when expanded. Therefore, the extraction lifecycle pre-expands all collapsed toggles in the LIVE document before cloning. Pages with no toggles pay zero cost (the helper returns immediately after the empty-querySelectorAll check); pages with toggles add 1-2 expansion passes at 500ms each (typical) or up to ~5s worst-case on pathologically nested pages.

**Inline-element shapes:** Links are real `<a href>`. Bold/italic are encoded as inline `style="font-weight: 600"` / `style="font-style: italic"` on a wrapping `<span>` (Notion does NOT use `<strong>`/`<em>`). Inline math is `<span class="notion-text-equation-token">` wrapping `<span class="katex">` → `<span class="katex-mathml">` → `<math><semantics>...<annotation encoding="application/x-tex">SRC</annotation></semantics></math>`. Inline code is `<div class="notion-inline-code-container">` (yes, a `<div>` inline within text — but it lays out inline via CSS).

**Strategy:** Inline walker preserves `<a href>`, drops Notion's styling spans by default, upgrades `font-weight: bold`/`>= 600` to `<strong>` and `font-style: italic` to `<em>`, replaces `notion-inline-code-container` with `<code>`, and synthesizes `<math data-latex>` from `<annotation>` for inline math so the reader's KaTeX re-renders (preserves `\textcolor`).

---

### Task 2: Add the unified extractor skeleton

**Files:**
- Modify: `scripts/clipper/src/clipper-defuddle.js` (add new top-level function `extractNotionPage(doc)` + helpers; do not yet remove the old normalizers)

- [ ] **Step 1: Write the dispatcher + per-block handlers (block-level)**

Top-of-file structure (above `normalizeNotionCodeBlocks` and friends):

```js
// Per-host Notion extractor. Replaces the piecemeal normalizers below.
// Returns clean semantic HTML for the article body, or null if the
// page isn't a Notion content page.
//
// Block-type coverage based on empirical inventory of
// https://yumoxu.notion.site/async-grpo-in-the-wild (2026-05-23).
// Notion ships new block types occasionally; unknown classes fall
// through to extractDefault() so nothing is lost.
function extractNotionPage(doc) {
  // Host gate (same as the old normalizers')
  let host = '';
  try { host = (location.hostname || '').toLowerCase(); } catch (_) { return null; }
  const isNotionHost =
    host === 'notion.site' || host.endsWith('.notion.site') ||
    host === 'notion.so'   || host.endsWith('.notion.so');
  if (!isNotionHost) return null;

  const blocks = Array.from(doc.querySelectorAll('[data-block-id]'));
  if (blocks.length === 0) return null;

  // Top-level blocks: those whose parent doesn't have data-block-id.
  // Nested data-block-id elements (e.g. list items inside a list block)
  // are walked by their owning block's handler.
  // NOTE: whether this filter is correct for nested lists depends on
  // Task 1 Step 1's nested-list probe finding. If Notion DOES nest
  // sub-bullets as [data-block-id] descendants, the list handler must
  // walk them and the filter is correct. If sub-bullets are flat siblings
  // with CSS-only indentation, the filter is also correct (they pass
  // through and get grouped by type). Either way, the filter is safe.
  const topLevel = blocks.filter((b) => !b.parentElement || !b.parentElement.closest('[data-block-id]'));

  // Pull the page title out of the notion-page-block (or null if none).
  // Notion's <title> tag is always "Notion" — Defuddle's title extraction
  // returns that, useless. We surface the real title here so the caller
  // can override payload.title.
  let pageTitle = null;
  for (let i = 0; i < topLevel.length; i++) {
    if (classifyBlock(topLevel[i]) === 'page') {
      const leaf = leafOf(topLevel[i]);
      pageTitle = leaf ? (leaf.textContent || '').trim() : null;
      break;
    }
  }

  const out = [];
  // Group consecutive list items into single <ul>/<ol> as we iterate.
  // The dispatcher handles the grouping; per-type handlers don't see
  // siblings.
  let i = 0;
  while (i < topLevel.length) {
    const block = topLevel[i];
    const type = classifyBlock(block);
    if (type === 'bulleted_list' || type === 'numbered_list') {
      const tag = type === 'bulleted_list' ? 'ul' : 'ol';
      const items = [];
      while (i < topLevel.length && classifyBlock(topLevel[i]) === type) {
        items.push(extractListItem(topLevel[i]));
        i++;
      }
      out.push('<' + tag + '>' + items.join('') + '</' + tag + '>');
      continue;
    }
    const html = extractBlock(block, type);
    if (html) out.push(html);
    i++;
  }

  return { content: out.join('\n'), title: pageTitle };
}

function classifyBlock(block) {
  const cls = block.className || '';
  // Order matters where one class name is a substring of another. The
  // sub_sub_header → sub_header → header chain is the canonical case:
  // `'notion-sub_header-block'.indexOf('notion-header-block')` is -1 (they
  // don't actually overlap as substrings — different separators), but other
  // future additions may. Check most-specific first as a defensive habit.
  if (cls.indexOf('notion-page-block') >= 0) return 'page';
  if (cls.indexOf('notion-sub_sub_header-block') >= 0) return 'h4';
  if (cls.indexOf('notion-sub_header-block') >= 0) return 'h3';
  if (cls.indexOf('notion-header-block') >= 0) return 'h2';
  if (cls.indexOf('notion-text-block') >= 0) return 'text';
  if (cls.indexOf('notion-bulleted_list-block') >= 0) return 'bulleted_list';
  if (cls.indexOf('notion-numbered_list-block') >= 0) return 'numbered_list';
  if (cls.indexOf('notion-code-block') >= 0) return 'code';
  if (cls.indexOf('notion-equation-block') >= 0) return 'equation_block';
  if (cls.indexOf('notion-image-block') >= 0) return 'image';
  if (cls.indexOf('notion-table-block') >= 0) return 'table';
  if (cls.indexOf('notion-table_of_contents-block') >= 0) return 'toc';
  if (cls.indexOf('notion-divider-block') >= 0) return 'divider';
  if (cls.indexOf('notion-toggle-block') >= 0) return 'toggle';
  if (cls.indexOf('notion-callout-block') >= 0) return 'callout';
  if (cls.indexOf('notion-quote-block') >= 0) return 'quote';
  if (cls.indexOf('notion-column_list-block') >= 0) return 'column_list';
  if (cls.indexOf('notion-column-block') >= 0) return 'column';
  if (cls.indexOf('notion-embed-block') >= 0) return 'embed';
  return 'unknown';
}

function extractBlock(block, type) {
  switch (type) {
    case 'page':           return ''; // skip: title is surfaced via payload.title (the
                                      // reader renders its own <h1> from the metadata, so
                                      // emitting one here would duplicate the title visually)
    case 'text':           return '<p>' + extractInline(leafOf(block)) + '</p>';
    case 'h2':             return '<h2>' + extractInline(leafOf(block)) + '</h2>';
    case 'h3':             return '<h3>' + extractInline(leafOf(block)) + '</h3>';
    case 'h4':             return '<h4>' + extractInline(leafOf(block)) + '</h4>';
    case 'code':           return extractCodeBlock(block);
    case 'equation_block': return extractEquationBlock(block);
    case 'image':          return extractImage(block);
    case 'table':          return extractTable(block);
    case 'toc':            return ''; // skip: TOC is reader-generated metadata, not content
    case 'divider':        return '<hr>';
    case 'toggle':         return extractToggle(block);
    case 'callout':        return extractCallout(block);
    case 'quote':          return extractQuote(block);
    case 'column_list':    return extractColumnList(block);
    case 'column':         return extractColumn(block); // typically reached only via column_list recursion
    case 'embed':          return extractEmbed(block);
    case 'unknown':        return extractDefault(block);
  }
  return '';
}

function leafOf(block) {
  // The data-content-editable-leaf attribute marks the in-block text container
  // (same convention we found for code blocks and lists).
  return block.querySelector('[data-content-editable-leaf="true"]');
}

function textOfLeaf(block) {
  const leaf = leafOf(block);
  return leaf ? (leaf.textContent || '') : '';
}

function escapeHTML(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
```

The placeholder helpers (`extractInline`, `extractListItem`, `extractCodeBlock`, etc.) get implemented in Step 2.

- [ ] **Step 2: Write the per-block-type handlers**

Implement each `extract*` helper. Code-block and list handlers can be lifted nearly verbatim from the current `normalizeNotionCodeBlocks` / `normalizeNotionLists`; image, table, equation_block need fresh code based on the inventory samples. The default handler is a safety net:

```js
function extractCodeBlock(block) {
  const leaf = leafOf(block);
  const codeText = leaf ? (leaf.textContent || '') : '';
  if (!codeText) return '';
  return '<pre><code>' + escapeHTML(codeText) + '</code></pre>';
}

function extractListItem(block) {
  const leaf = leafOf(block);
  return '<li>' + (leaf ? extractInline(leaf) : '') + '</li>';
}

function extractEquationBlock(block) {
  // Notion server-renders equations via KaTeX; the markup has a
  // <span class="katex"><span class="katex-mathml"><math><semantics>...
  // <annotation encoding="application/x-tex">SRC</annotation></semantics>
  // </math></span><span class="katex-html">...</span></span> chain.
  //
  // We synthesize `<math display="block" data-latex="SRC">` so the
  // reader's renderMath() Pass 1 re-renders via its bundled KaTeX,
  // which handles \textcolor correctly. (Notion's server-side temml
  // strips \textcolor during MathML conversion — same limitation we
  // hit earlier on inline math.)
  const annotation = block.querySelector('annotation[encoding="application/x-tex"]');
  if (annotation) {
    const latex = annotation.textContent || '';
    if (latex) return '<math display="block" data-latex="' + escapeHTML(latex) + '"></math>';
  }
  // Fallback chain: preserve the katex span verbatim if no annotation found.
  const katex = block.querySelector('.katex');
  if (katex) return '<div class="rubien-equation-block">' + katex.outerHTML + '</div>';
  return '<p>' + escapeHTML(textOfLeaf(block) || block.textContent || '') + '</p>';
}

function extractImage(block) {
  const img = block.querySelector('img');
  if (!img) return '';
  const rawSrc = img.getAttribute('src') || img.getAttribute('data-src') || '';
  const src = safeHref(rawSrc);
  if (!src) return '';
  const alt = img.getAttribute('alt') || '';
  let figcaption = '';
  // Notion image captions live in a sibling/descendant element; check for
  // [data-content-editable-leaf] under the image-block that's NOT the image.
  const caption = block.querySelector('[data-content-editable-leaf="true"]');
  if (caption && caption.textContent && caption.textContent.trim()) {
    figcaption = '<figcaption>' + extractInline(caption) + '</figcaption>';
  }
  return '<figure><img src="' + escapeHTML(src) + '" alt="' + escapeHTML(alt) + '">' + figcaption + '</figure>';
}

function extractTable(block) {
  // Notion table-block contains a real <table> already; reuse it but
  // strip Notion's inline styles and sanitize attributes. Tables can
  // contain inline anchors (<a href>) and images (<img src>) which would
  // bypass safeHref/escapeHTML otherwise — the cloned outerHTML goes
  // straight into the reader without further sanitization.
  const t = block.querySelector('table');
  if (!t) return '';
  const clone = t.cloneNode(true);
  const all = clone.querySelectorAll('*');
  for (const el of all) {
    el.removeAttribute('style');
    el.removeAttribute('class');
    // Drop ALL on* event handler attributes (onclick, onerror, etc.)
    const toRemove = [];
    for (const attr of el.attributes) {
      if (/^on/i.test(attr.name)) toRemove.push(attr.name);
    }
    for (const name of toRemove) el.removeAttribute(name);
    // Sanitize URL-bearing attributes against safeHref allow-list.
    // href: <a>; src: <img>/<source>/<iframe>/<embed>; srcset: <img>/<source>
    // (comma-separated candidate list); xlink:href: SVG <use>/<a>.
    for (const name of ['href', 'src', 'xlink:href']) {
      if (el.hasAttribute(name)) {
        const safe = safeHref(el.getAttribute(name));
        if (safe) el.setAttribute(name, safe);
        else el.removeAttribute(name);
      }
    }
    if (el.hasAttribute('srcset')) {
      const raw = el.getAttribute('srcset') || '';
      const safeParts = raw.split(',').map((part) => {
        const trimmed = part.trim();
        if (!trimmed) return null;
        const spaceIdx = trimmed.search(/\s/);
        const url = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx);
        const descriptor = spaceIdx === -1 ? '' : trimmed.slice(spaceIdx);
        const safe = safeHref(url);
        return safe ? safe + descriptor : null;
      }).filter(Boolean);
      if (safeParts.length) el.setAttribute('srcset', safeParts.join(', '));
      else el.removeAttribute('srcset');
    }
  }
  return clone.outerHTML;
}

function extractDefault(block) {
  // Unknown block type — preserve the text in a div so nothing is silently
  // lost. Log via debug channel so we know to add a handler.
  return '<div class="rubien-notion-unknown" data-notion-classes="' +
    escapeHTML(block.className || '') + '">' +
    escapeHTML(block.textContent || '') + '</div>';
}

// ---- Container blocks (toggle / callout / quote / columns / embed) ----

// Walk DIRECT child [data-block-id] elements of `container` and dispatch
// each through the normal dispatcher (with list-grouping support). Used by
// toggle, callout, column. Returns concatenated HTML string.
function walkChildBlocks(container) {
  const children = Array.from(container.querySelectorAll('[data-block-id]'))
    .filter((b) => b.parentElement && b.parentElement.closest('[data-block-id]') === container);
  const out = [];
  let i = 0;
  while (i < children.length) {
    const c = children[i];
    const type = classifyBlock(c);
    if (type === 'bulleted_list' || type === 'numbered_list') {
      const tag = type === 'bulleted_list' ? 'ul' : 'ol';
      const items = [];
      while (i < children.length && classifyBlock(children[i]) === type) {
        items.push(extractListItem(children[i]));
        i++;
      }
      out.push('<' + tag + '>' + items.join('') + '</' + tag + '>');
      continue;
    }
    const html = extractBlock(c, type);
    if (html) out.push(html);
    i++;
  }
  return out.join('\n');
}

function extractToggle(block) {
  // The toggle's own label lives in the data-content-editable-leaf directly
  // under the toggle (not under any descendant data-block-id).
  const leaf = leafOf(block);
  const label = leaf ? extractInline(leaf) : '';
  // Children should be DOM-present because we pre-expanded all toggles
  // before cloning. If the pre-expansion failed for any reason, the
  // <details> still renders with just the label visible.
  const body = walkChildBlocks(block);
  return '<details open><summary>' + label + '</summary>' + body + '</details>';
}

function extractCallout(block) {
  // Callout DOM has two leaves typically: the icon (emoji or empty) and the
  // body. The icon is usually a sibling span before the leaf; capture
  // whatever non-empty leading character we can find.
  let icon = '';
  const iconHost = block.querySelector('.notion-record-icon, [role="img"]');
  if (iconHost) icon = (iconHost.textContent || '').trim();
  const leaf = leafOf(block);
  const body = leaf ? extractInline(leaf) : '';
  // Some callouts have nested blocks (multi-paragraph callouts). Include them.
  const nested = walkChildBlocks(block);
  const inner = (icon ? '<span class="rubien-notion-callout-icon">' + escapeHTML(icon) + '</span> ' : '') +
                body + (nested ? nested : '');
  return '<aside class="rubien-notion-callout">' + inner + '</aside>';
}

function extractQuote(block) {
  const leaf = leafOf(block);
  return '<blockquote>' + (leaf ? extractInline(leaf) : '') + '</blockquote>';
}

function extractColumnList(block) {
  // Readers don't have horizontal real estate; stack columns vertically
  // by walking each column's children inline. No outer wrapper.
  const cols = Array.from(block.querySelectorAll('div.notion-column-block[data-block-id]'))
    .filter((c) => c.parentElement && c.parentElement.closest('[data-block-id]') === block);
  return cols.map((c) => walkChildBlocks(c)).filter((s) => s).join('\n');
}

function extractColumn(block) {
  // Reached only if a stray column-block appears without its column_list
  // wrapper (shouldn't happen in practice). Walk its children.
  return walkChildBlocks(block);
}

// Validate href schemes before emitting <a href=...>. Anything not in this
// allow-list is rendered as plain text (escaped). Notion content goes
// directly into the reader's #article-content via WebReaderView (it doesn't
// pass through Defuddle's sanitization for our overridden payload.content),
// so we cannot rely on downstream sanitization.
function safeHref(raw) {
  const s = String(raw || '').trim();
  if (!s) return null;
  // Allow relative URLs (start with /, ./, ../, #, ?)
  if (/^[/?#]/.test(s) || /^\.\.?\//.test(s)) return s;
  // Allow http(s), mailto, tel — block javascript:, data:, vbscript:, file:
  if (/^(https?|mailto|tel):/i.test(s)) return s;
  return null;
}

function extractEmbed(block) {
  // Render a placeholder so users know something was there. Pull the iframe
  // src if available — that's typically the upstream URL the embed points to.
  const iframe = block.querySelector('iframe');
  const rawSrc = iframe ? (iframe.getAttribute('src') || '') : '';
  const src = safeHref(rawSrc);
  if (src) {
    return '<div class="rubien-notion-embed">[Embed: <a href="' + escapeHTML(src) + '">' + escapeHTML(src) + '</a>]</div>';
  }
  // No src (or unsafe scheme) — emit a placeholder with whatever text is in
  // the block (e.g. bookmark cards often have a title leaf).
  const text = (block.textContent || '').trim();
  return '<div class="rubien-notion-embed">[Embed' + (text ? ': ' + escapeHTML(text.slice(0, 200)) : '') + ']</div>';
}
```

- [ ] **Step 3: Write the inline walker**

`extractInline(leaf)` walks the leaf's children and emits semantic inline HTML. Implementation strategy depends on Task 1 Step 2 findings. Sketch:

```js
function extractInline(leaf) {
  if (!leaf) return '';
  const out = [];
  for (const node of leaf.childNodes) {
    if (node.nodeType === 3 /* TEXT_NODE */) {
      out.push(escapeHTML(node.nodeValue || ''));
      continue;
    }
    if (node.nodeType !== 1 /* ELEMENT_NODE */) continue;
    const el = node;
    const cls = el.className || '';
    // Inline code (notion-inline-code-container is a <div> by Notion's
    // convention but here it appears inline within the leaf; emit <code>).
    if (typeof cls === 'string' && cls.indexOf('notion-inline-code-container') >= 0) {
      out.push('<code>' + escapeHTML(el.textContent || '') + '</code>');
      continue;
    }
    // Inline math: notion-text-equation-token wraps a .katex span which
    // wraps .katex-mathml > <math><semantics> ... <annotation encoding=
    // "application/x-tex">SRC</annotation></semantics></math>. We extract
    // the LaTeX source and synthesize a `<math data-latex="SRC">` element
    // (no display attr → defaults to inline). The reader's renderMath()
    // Pass 1 picks it up and re-renders via KaTeX, which handles \textcolor
    // correctly. Preserving Notion's pre-rendered katex span verbatim
    // would visually display but skip the reader's color-fixing Pass 1.
    if (typeof cls === 'string' && cls.indexOf('notion-text-equation-token') >= 0) {
      const annotation = el.querySelector('annotation[encoding="application/x-tex"]');
      const latex = annotation ? (annotation.textContent || '') : '';
      if (latex) {
        out.push('<math data-latex="' + escapeHTML(latex) + '"></math>');
        continue;
      }
      // Fallback: if no annotation, preserve the katex span verbatim so
      // we don't lose the visual rendering.
      const katex = el.querySelector('.katex');
      if (katex) { out.push(katex.outerHTML); continue; }
    }
    // Real links — validate scheme to block javascript:, data:, etc.
    if (el.tagName === 'A') {
      const href = safeHref(el.getAttribute('href') || '');
      if (href) {
        out.push('<a href="' + escapeHTML(href) + '">' + extractInline(el) + '</a>');
      } else {
        // Unsafe href: emit text content only.
        out.push(extractInline(el));
      }
      continue;
    }
    // Bold / italic / strong / em — preserve semantic tags
    if (['STRONG', 'B', 'EM', 'I', 'U', 'S', 'CODE'].indexOf(el.tagName) >= 0) {
      out.push('<' + el.tagName.toLowerCase() + '>' + extractInline(el) + '</' + el.tagName.toLowerCase() + '>');
      continue;
    }
    // Bold via inline style — recognize style="font-weight: 700"/"bold"
    const style = el.getAttribute('style') || '';
    if (/font-weight\s*:\s*(bold|[6-9]\d\d)/i.test(style)) {
      out.push('<strong>' + extractInline(el) + '</strong>');
      continue;
    }
    if (/font-style\s*:\s*italic/i.test(style)) {
      out.push('<em>' + extractInline(el) + '</em>');
      continue;
    }
    // Default: recurse into the element, drop its wrapping
    out.push(extractInline(el));
  }
  return out.join('');
}
```

- [ ] **Step 4: Lint check**

```bash
cd scripts/clipper && node --check src/clipper-defuddle.js && echo OK
```

---

### Task 3: Wire `extractNotionPage` into `RubienDefuddleExtract`

**Files:**
- Modify: `scripts/clipper/src/clipper-defuddle.js`

- [ ] **Step 1: Wrap the body in an async IIFE — KEEP the outer function synchronous**

The current implementation declares `window.RubienDefuddleExtract = function RubienDefuddleExtract() { ... }` — a plain synchronous function. The async branch (parseAsync) already returns `undefined` and relies on postMessage for delivery; the sync branch returns a JSON string that Swift's `processDefuddleJSONFallback` (`ReaderExtractionManager.swift:139`) parses as a safety net.

Converting the outer to `async function` would change the return type to a Promise object, which `evaluateJavaScript` cannot serialize — the JSON fallback at `ReaderExtractionManager.swift:139` would parse `nil` and fall back to Readability whenever postMessage missed its 200ms window. To preserve the contract, keep the outer function sync and wrap the body that needs `await` in an inner async IIFE:

```js
window.RubienDefuddleExtract = function RubienDefuddleExtract() {
  // Sync setup that doesn't need await (handler caching, debugPost, etc.)
  const mh = (typeof window !== 'undefined' && window.webkit && window.webkit.messageHandlers) || null;
  const dbgCh = mh && mh.RubienClipperDebug;
  const resCh = mh && mh.readerResult;
  const pageURL = (typeof document !== 'undefined' && document.URL) || '';
  function debugPost(phase, detail) { /* ... unchanged ... */ }
  function postResult(payload) { /* ... unchanged ... */ }
  let delivered = false;
  function deliver(payload) { /* ... unchanged ... */ }
  function exitError(prefix, err) { /* ... unchanged ... */ }

  // preExpandNotionToggles MUST be defined here so it closes over debugPost.
  async function preExpandNotionToggles() { /* defined in Step 2 below */ }

  // The Defuddle + Notion-extractor pipeline needs `await` — wrap it in an
  // IIFE. The outer function returns undefined; postMessage (via `deliver`)
  // is the canonical delivery channel. Swift's JSON fallback at
  // ReaderExtractionManager.swift:139 will parse undefined → fall back to
  // Readability, but this only fires if `defuddleResultHandled` is still
  // false after 200ms (i.e. postMessage was missed entirely). In practice
  // postMessage always wins.
  (async () => {
    try {
      debugPost('rubien_defuddle_extract_start');
      await preExpandNotionToggles();
      // ...rest of current body, with `return undefined` swaps removed since
      // we're inside an IIFE — exitError calls already postMessage via deliver...
    } catch (err) {
      exitError('uncaught: ', err);
    }
  })();

  return undefined;
};
```

The sync fallback branch (where `parseAsync` is absent) becomes effectively cosmetic — its `return deliver(payload)` value is returned to the IIFE, not to Swift. Acceptable: Defuddle 0.18.1 always provides `parseAsync`, so the sync branch is already dead code.

- [ ] **Step 2: Define `preExpandNotionToggles` INSIDE `RubienDefuddleExtract` so it can close over `debugPost`**

`debugPost` is a nested function scoped inside `RubienDefuddleExtract`. Define the helper inline near the top of the outer function (after `debugPost` is declared), NOT at module scope:

```js
// Inside RubienDefuddleExtract, after debugPost is defined:
async function preExpandNotionToggles() {
  let host = '';
  try { host = (location.hostname || '').toLowerCase(); } catch (_) { return; }
  const isNotion =
    host === 'notion.site' || host.endsWith('.notion.site') ||
    host === 'notion.so'   || host.endsWith('.notion.so');
  if (!isNotion) return;

  // Iterative expansion: clicking a collapsed parent reveals its lazy
  // children, which may themselves contain collapsed toggles. Loop until
  // we observe TWO consecutive passes with zero collapsed toggles
  // (defends against the early-break race where a re-render lands just
  // after our querySelectorAll returns empty but before the next pass).
  // Cap at 10 passes for safety — pathological pages with deeper nesting
  // accept a less-complete extraction rather than hanging the wrapper.
  const MAX_PASSES = 10;
  const WAIT_MS = 500;
  // Only target the toggle's OWN disclosure button, not any descendant
  // [aria-expanded="false"] (which could include other interactive
  // widgets nested inside an expanded toggle's content).
  const SELECTOR = 'div.notion-toggle-block > div [aria-expanded="false"][role="button"]:not(a):not([href])';
  let totalExpanded = 0;
  let consecutiveEmpty = 0;
  for (let pass = 0; pass < MAX_PASSES; pass++) {
    const buttons = document.querySelectorAll(SELECTOR);
    if (buttons.length === 0) {
      consecutiveEmpty++;
      if (consecutiveEmpty >= 2) break;
      // Wait one more cycle in case a late re-render is in flight.
      await new Promise((resolve) => setTimeout(resolve, WAIT_MS));
      continue;
    }
    consecutiveEmpty = 0;
    for (const b of buttons) {
      try { b.click(); } catch (_) { /* ignore */ }
      totalExpanded++;
    }
    await new Promise((resolve) => setTimeout(resolve, WAIT_MS));
  }
  debugPost('rubien_defuddle_notion_toggles_expanded',
    'count=' + totalExpanded);
}
```

- [ ] **Step 3: Call `preExpandNotionToggles()` then replace the three normalizer call sites with the unified extractor**

Find the block that calls the old normalizers (`let workingDoc = document;` etc.) and replace with:

```js
await preExpandNotionToggles();

let workingDoc = document;
let notionExtract = null; // { content, title } | null
try {
  const clone = document.cloneNode(true);
  notionExtract = extractNotionPage(clone);
  if (notionExtract != null) {
    debugPost('rubien_defuddle_notion_extracted',
      'len=' + notionExtract.content.length + ' title=' + (notionExtract.title ? 'yes' : 'no'));
  }
  workingDoc = clone;
} catch (err) {
  debugPost('rubien_defuddle_notion_failed', err && err.message);
  // Fall back to live document so Defuddle still runs.
}
```

The hidden WKWebView is never user-visible, so the toggle flip-open is an invisible side effect. Non-Notion hosts pay zero cost (the helper returns immediately after host gate).

- [ ] **Step 4: Override `payload.content` AND `payload.title` with Notion-extracted values on success**

Currently `buildPayload(result, null)` uses `result.content` and `result.title` (Defuddle's). We override BOTH when the Notion extractor returned something — Defuddle's title for Notion pages is always literally "Notion" (the shell `<title>` tag), which is wrong; the real title lives in `notion-page-block` and `extractNotionPage` surfaces it as `notionExtract.title`.

In the async branch:

```js
.then((result) => {
  clearTimeout(timer);
  debugPost('rubien_defuddle_parse_async_end');
  const payload = buildPayload(result, null);
  if (notionExtract != null) {
    payload.content = notionExtract.content;
    payload.ok = notionExtract.content.trim().length > 0;
    if (notionExtract.title) {
      payload.title = notionExtract.title;
    }
  }
  debugPost('rubien_defuddle_exit', 'ok=' + payload.ok);
  deliver(payload);
})
```

Same override in the sync branch.

- [ ] **Step 5: Delete the three old normalizer functions**

Now that `extractNotionPage` covers their functionality, remove:
- `normalizeNotionCodeBlocks`
- `normalizeNotionLists`
- `normalizeNotionInlineCode`

Plus their call site (already removed in Step 1 above). The whole-file diff should be: 3 functions deleted, 1 large new function added, 1 call-site swap.

---

### Task 4: Rebuild bundle, verify swift build, verify extraction via Playwright

**Files:**
- Modify (regenerate): `Sources/Rubien/Resources/ClipperDefuddle.js`

- [ ] **Step 1: Build**

```bash
cd scripts/clipper && npm run build
```

Expected: bundle size similar to current (~685 KB) since we're not adding or removing dependencies.

- [ ] **Step 2: Swift build**

```bash
cd /Users/hzzheng/CodeHub/Rubien && swift build --target Rubien 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 3: Extend `scripts/clipper-test/verify-extraction.mjs` checks**

Add structural assertions for the new block types:
- `imgCount` > 0
- `tableCount` > 0
- `h3Count` > 0
- `h4Count` > 0
- `hrCount` > 0 (divider)
- math/code/list counts still pass (no regression)
- Debug channel includes `rubien_defuddle_notion_extracted`

Re-run:
```bash
cd scripts/clipper-test && npm run verify-extraction
```

Expected: all checks pass, no regression on existing math/code/list counts.

---

### Task 5: Send to Codex for review

**Files:** (no edits — review)

The unified extractor is significantly larger than the previous normalizers (estimated 200-300 lines). Two Codex passes likely warranted:

- **Pass 1 (broad):** focus on the dispatch logic, host gate, classifier correctness, default-handler safety, inline walker recursion depth, escapeHTML coverage of all output sites.
- **Pass 2 (if Pass 1 finds anything):** verify the patches.

Pass 1 focus areas:
1. **`classifyBlock` indexOf chain.** Each `if (cls.indexOf('notion-X-block') >= 0)` — does any pair of class names overlap (one being a substring of another) such that the order of checks matters? Manually verified for the 19 currently-handled classes: no full-name substring overlaps. But the chain is still ordered most-specific-first (sub_sub_header → sub_header → header, column_list → column) as a defensive habit for future additions. Codex: verify the ordering still holds after any class additions.
2. **`extractInline` recursion termination.** What happens if Notion's DOM has a cycle (it shouldn't, but the code should still terminate)? Or extreme nesting depth?
3. **HTML escaping consistency.** Are all string concatenations into HTML escaped (text content, attributes)? Common bug source. Particular attention: `extractEmbed`'s `src`, `extractCallout`'s `icon`, `extractToggle`'s label going through `extractInline` (which itself emits raw HTML for `<a>` / `<strong>` / `<code>` — verify those are constructed safely).
4. **Top-level vs nested block filtering.** `!b.parentElement.closest('[data-block-id]')` — does this correctly exclude nested blocks? Now particularly important because toggle/callout/column children ARE nested `[data-block-id]` elements (after pre-expansion for toggles), and they must NOT be re-emitted as top-level blocks.
5. **`walkChildBlocks` direct-child filter.** `parentElement.closest('[data-block-id]') === container` — verify this correctly captures only direct children (no grandchildren leaking through).
6. **List grouping correctness.** Two consecutive bulleted lists with a non-list block between them should produce two separate `<ul>` elements, not one merged. Verify in both `extractNotionPage` and `walkChildBlocks`.
7. **Math equation block fallback chain.** Three fallbacks (annotation → katex span → text). Does each emit valid HTML?
8. **Toggle pre-expansion side effects.** Clicking `[aria-expanded="false"]` buttons in the live document is a Notion-app interaction. Verify no analytics/network requests are triggered that would surprise users. (WKWebView is hidden, but the page's JS still runs.)
9. **Pre-expansion timing.** 500ms-per-pass × up to 10 passes (with two-consecutive-empty confirmation for early-break safety). Acceptable for v1, but consider MutationObserver upgrade if real-world telemetry shows pages hitting the MAX_PASSES cap.

---

### Task 6: Smoke test via the UI

**Files:** (none — manual)

- [ ] **Step 1: Launch + re-clip**

```bash
swift run Rubien
```

Re-clip `https://yumoxu.notion.site/async-grpo-in-the-wild` (delete any prior copy first or compare as new).

- [ ] **Step 2: Visual verification checklist**

In the reader, scroll through the entire post and verify:
- [ ] H1 (page title) renders large
- [ ] H3 / H4 section headings render with appropriate weight/size
- [ ] Paragraphs flow correctly, no surprise line breaks
- [ ] Inline code (e.g., `staleness_threshold`) renders monospace inline with prose
- [ ] Inline math (single-character vars like `K`) renders as KaTeX
- [ ] Block code (the pseudo-code blocks) renders monospace with preserved indentation
- [ ] Block math equations render correctly with proper sizing
- [ ] Bullet lists have visible bullets, items stacked correctly
- [ ] Numbered lists have visible numbers
- [ ] Tables render with rows, columns, borders
- [ ] Images appear with their captions (if any)
- [ ] Dividers (`<hr>`) appear as horizontal lines
- [ ] Toggles render as collapsible `<details>` blocks (open by default; their children are visible)
- [ ] Callouts render as `<aside>` with their icon prefix (if any) + body
- [ ] Quotes render as `<blockquote>`
- [ ] Side-by-side columns appear stacked vertically (acceptable degradation)
- [ ] Embeds show as `[Embed: <link>]` placeholders, not blank or broken
- [ ] No raw `\textcolor`, `\frac`, or other LaTeX leakage
- [ ] Links remain clickable
- [ ] `\textcolor{magenta}` math still renders in color (KaTeX re-render preserves this)

- [ ] **Step 3: Smoke test the three probed Notion pages (mandatory)**

Re-clip each of:
- `https://yumoxu.notion.site/async-grpo-in-the-wild` (math + code heavy)
- `https://yumoxu.notion.site/a-gradient-level-look-at-ppo-grpo-and-cispo` (math heavy, `\textcolor`)
- `https://yaofu.notion.site/Full-Stack-Transformer-Inference-Optimization-Season-2-Deploying-Long-Context-Models-ee25d3a77ba14f73b8ae19147f77d5e2` (toggles + callouts + columns + the BibTeX-in-toggle case)

For each, verify:
- Page title is correct (the real post title, not "Notion")
- Block types render correctly: toggle expands to `<details>` showing its children (the BibTeX cite block inside the yaofu page MUST appear), callout renders as `<aside>`, columns stack vertically, embeds show as `[Embed: ...]` placeholder
- No regression on math/code/lists/inline-code/images
- Debug channel shows `rubien_defuddle_notion_toggles_expanded` with non-zero count on the yaofu page

If `extractDefault` is hit for any block type (check via `<div class="rubien-notion-unknown">` in the rendered output), add a dedicated handler in a follow-up commit rather than blocking this one — flag in the smoke-test summary.

- [ ] **Step 4: Smoke test 1-2 non-Notion pages**

Verify the host gate works: clip an arXiv abstract and one Substack/Medium post. The extractor should NOT activate (no `rubien_defuddle_notion_extracted` debug entry), and Defuddle's normal output should be unchanged.

---

### Task 7: Commit

**Files:** (commits the work)

- [ ] **Step 1: Inspect staged diff**

```bash
git status --short
```

Expected modifications:
- `scripts/clipper/src/clipper-defuddle.js` (3 normalizer functions removed, 1 unified extractor + helpers added, call-site updated)
- `Sources/Rubien/Resources/ClipperDefuddle.js` (regenerated bundle)
- `scripts/clipper-test/verify-extraction.mjs` (extended structural checks)

Expected new files:
- `scripts/clipper-test/diagnose-notion-inline.mjs` (probe from Task 1, useful for future iteration)
- `scripts/clipper-test/diagnose-notion-inventory.mjs` (probe from Task 1)
- `scripts/clipper-test/diagnose-notion-novel.mjs` (probe from Task 1)
- `scripts/clipper-test/diagnose-notion-toggle.mjs` (probe from Task 1 — definitive evidence for the pre-expansion lifecycle decision)
- `Docs/superpowers/plans/2026-05-23-unified-notion-extractor.md` (this plan)

NOT expected:
- Any change to `Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift` (discriminator stays in working tree)
- Any change to `Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift` beyond what Step 2 below specifies (the 5s discriminator stays — reverted in its own follow-up)

- [ ] **Step 2: Update CLIPPER_BUNDLE.txt to document the new debug phase**

The debug-phase rename from `rubien_defuddle_normalize` to `rubien_defuddle_notion_extracted` + `rubien_defuddle_notion_failed` should be reflected in the contract section. Include the file in the commit.

- [ ] **Step 3: Stage explicitly and commit**

```bash
git add scripts/clipper/src/clipper-defuddle.js \
        Sources/Rubien/Resources/ClipperDefuddle.js \
        Sources/Rubien/Resources/CLIPPER_BUNDLE.txt \
        scripts/clipper-test/verify-extraction.mjs \
        scripts/clipper-test/diagnose-notion-inventory.mjs \
        scripts/clipper-test/diagnose-notion-inline.mjs \
        scripts/clipper-test/diagnose-notion-novel.mjs \
        scripts/clipper-test/diagnose-notion-toggle.mjs \
        Docs/superpowers/plans/2026-05-23-unified-notion-extractor.md

git commit -m "$(cat <<'EOF'
clipper: unified Notion per-host extractor (replaces piecemeal normalizers)

The previous piecemeal approach (one normalizer per Notion block type)
hit a regression-whack-a-mole pattern: each normalizer risked breaking
another shape's extraction. Replaced with a single extractNotionPage(doc)
that walks Notion's [data-block-id] tree top-to-bottom and dispatches
each block to a per-class handler.

Block-type coverage (gathered empirically from three Notion blogs —
async-grpo, ppo-grpo-cispo, full-stack-transformer-inference): page
(skipped — title surfaced via payload.title metadata), text (p),
header/sub_header/sub_sub_header (h2/h3/h4), bulleted_list/numbered_list
(ul/ol with grouping), code (pre/code), equation (<math display="block"
data-latex=...> synthesized from <annotation> so reader re-renders via
KaTeX), image (figure/img+figcaption), table (strip styling, keep
semantic table markup), divider (hr), toc (skip), toggle
(<details open><summary>label</summary>children</details>), callout
(<aside class="rubien-notion-callout">icon + body</aside>), quote
(<blockquote>), column_list/column (stacked vertically — no horizontal
real estate in the reader), embed (placeholder <div class=
"rubien-notion-embed">[Embed: <a>src</a>]</div> so users know
something was there). Unknown classes fall through to a default handler
that preserves the text in a div so nothing is silently lost.

Inline-element walker: real <a href> preserved, inline math
(notion-text-equation-token) synthesizes <math data-latex=...> from its
inner <annotation> so the reader's renderMath() Pass 1 re-renders via
KaTeX (preserves \textcolor), inline code (notion-inline-code-container)
emitted as <code>, font-weight: 600/bold spans upgraded to <strong>,
font-style: italic spans upgraded to <em>.

Toggle children are React-lazy: not in the DOM when collapsed. Pre-expand
all toggles in the live document (button.click() on
[aria-expanded="false"]) iteratively with 500ms-per-pass + two-empty
confirmation, then clone. WKWebView is hidden so the flip-open is
invisible to users.

Architecture: pre-expand toggles → clone document (avoids React
reconciliation for the rest) → run Notion extractor on clone → run
Defuddle on clone for metadata (description, author, image). Defuddle's
metadata pipeline is solid; we keep that. Override payload.content with
the Notion extractor's HTML, and payload.title with the real page title
from notion-page-block (Defuddle's title would be literally "Notion" —
the shell <title> tag).

Upstream PR to github.com/kepano/defuddle as a per-host extractor
module: separate follow-up plan.

Smoke-tested on three Notion pages plus arXiv/Substack non-Notion
controls — all block types render correctly, inline code flows inline,
math (block + inline) renders via KaTeX with \textcolor preserved, no
regression on non-Notion clips.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

**Spec coverage:** Plan addresses the architectural pivot the user requested. Three piecemeal normalizers are replaced with one unified extractor. Block-type coverage is grounded in empirical inventory captured during planning (the table in the plan's intro). Inline-element coverage requires Task 1 probe before locking in the walker, which is honest about what we know vs. what needs verification.

**Placeholder scan:** Task 1's findings are recorded as concrete probe outputs (the 19 block-class inventory, the toggle lazy-render finding, the inline shape mapping); Task 2 Step 3's inline walker code is finalized based on those findings; Task 5 lists concrete Codex focus areas (substring-overlap defense, recursion termination, escaping consistency, pre-expansion side effects, timing); Task 6 has a concrete visual checklist naming each block type; Task 7's commit body is fully drafted — the implementer should verify the smoke-test claims (three Notion pages + arXiv/Substack controls) match what was actually re-tested at commit time, and trim/adjust if any block type didn't render as expected.

**Type consistency:** All `extract*` per-block helpers take a single `block` (Element) or `leaf` (Element) and return a string. `classifyBlock` returns a string. `walkChildBlocks(container)` returns a string. `extractNotionPage(doc)` returns `{ content: string, title: string|null } | null` (null when the host gate rejects). `preExpandNotionToggles()` returns `Promise<void>`. `safeHref(raw)` returns `string|null`. Consistent.

**Known limitations / follow-ups not in this plan:**
- **Upstream PR.** Once the local implementation is stable, the same extractor logic should be packaged as a Defuddle extractor module (their convention) and submitted to `github.com/kepano/defuddle`. Until then, we maintain it downstream.
- **Speculative block types.** `notion-to_do-block`, `notion-bookmark-block`, `notion-video-block`, `notion-audio-block`, `notion-file-block`, `notion-synced_block` were NOT observed on any of the three probed pages. They fall through to `extractDefault` (text-only). Add dedicated handlers when users hit them in production.
- **`classifyBlock` substring chain.** Manually verified: none of the 19 currently-handled `notion-X-block` class names is a proper substring of another (the `notion-sub_header-block` ⊃ `notion-header-block` case I initially suspected does NOT hold — `notion-sub_header-block` does not contain `notion-header-block` as a substring because of the `sub_` prefix). The chain is still ordered most-specific-first as a defensive habit for future additions. Any new `notion-X-block` class added later must be checked for substring overlap.
- **Inline math (`notion-text-equation-token`) re-rendering.** The inline walker synthesizes `<math data-latex="LATEX">` from the inner `<annotation encoding="application/x-tex">`. The reader's renderMath() Pass 1 picks both inline (`display` absent) and block (`display="block"`) `<math data-latex>` elements via the same selector and re-renders via bundled KaTeX, which handles `\textcolor` correctly. Same code path as `extractEquationBlock`.
- **Title duplication avoided.** `notion-page-block` is the title element; `extractNotionPage` extracts its text as `pageTitle` and overrides `payload.title`. The `page` case in `extractBlock` returns empty string so we don't emit a duplicate `<h1>` in body (the reader renders its own header from `payload.title`).
- **Title override is not persisted to `Reference` (follow-up).** `ReaderExtractionManager` consumes `payload.title` and passes it as `headerTitle` into the live render via `WebReaderViewModel.applyReadableExtractionResult`, but it does NOT write the normalized title back to the `Reference` record. Result: live render shows the correct title; subsequent clipped-mode renders fall back to whatever `reference.title` was set at clip time (likely the literal "Notion"). Follow-up plan: persist normalized title to `Reference.title` when the Notion extractor surfaces one. Out of scope here because it touches the reference-write path, not the extractor itself.
- **Toggle pre-expansion is a live-DOM side effect.** Clicking Notion's toggle buttons in the live document fires React event handlers (and any of Notion's analytics that hook into those). WKWebView is hidden so the visual change is invisible, but network requests from analytics still happen. Acceptable trade-off: users opted into clipping the page anyway. If this becomes a privacy concern, alternative is to forge React state directly (fragile).
- **Pre-expansion uses 500ms-per-pass + two-empty confirmation, capped at 10 passes.** Worst case ~5s extra on pathologically nested Notion pages; typical case 1-2 passes. If telemetry shows pages hitting the MAX_PASSES cap or missing toggle children, upgrade to MutationObserver-based "wait until DOM quiet" detection.
- **Column layout flattens to vertical stack.** Two side-by-side columns become two consecutive content blocks. Acceptable for reader UI; structural information (which content was paired horizontally) is lost.
- **Callout icon is best-effort.** Notion's callout icon DOM varies — emoji, image, or empty. We grab whatever text content is in the icon host element. Image icons render as empty string (acceptable: the callout still shows as `<aside>` with body content).
