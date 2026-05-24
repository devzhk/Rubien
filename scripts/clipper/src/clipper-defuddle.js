// Bridges Defuddle's parse() / parseAsync() result to the JSON contract
// that Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift expects,
// and preserves the RubienClipperDebug diagnostic channel that
// Sources/Rubien/Views/WebReaderView.swift:1725 (registration) and
// :1997 (consumer) rely on.
//
// Two delivery channels for the result:
//   1. webkit.messageHandlers.readerResult.postMessage(payload)  — canonical
//   2. return JSON.stringify(payload)                            — sync-only fallback
//      (Swift's processDefuddleJSONFallback fires after a safety-net
//       timeout if postMessage hasn't landed — currently 8s, see
//       ReaderExtractionManager.swift. The outer function is sync but
//       wraps the work in an async IIFE; sync return is always undefined,
//       so postMessage is the only practical channel.)
//
// We import `defuddle/full` because Notion (and similar SPAs that use
// KaTeX) emit math as raw LaTeX strings in the DOM and rely on a runtime
// renderer. Core `defuddle` extracts those strings as plain text and
// stops; `defuddle/full` includes `temml` + `mathml-to-latex` which
// convert the LaTeX into `<math>` elements at extraction time so the
// reader can render them. This costs ~400 KB of bundle size vs core;
// confirmed necessary by a smoke test against a math-heavy Notion post.

import Defuddle from 'defuddle/full';

const SOURCE = 'defuddle';
// Matches the timeout the previous obsidian-clipper bundle enforced.
// Only effective on the parseAsync path; sync `.parse()` can't be canceled.
const PARSE_TIMEOUT_MS = 45_000;

// ============================================================================
// Unified Notion per-host extractor.
//
// Replaces the three piecemeal normalizers (code blocks, lists, inline
// code) below with a single tree walk over [data-block-id] elements.
// Each block type has a dedicated handler that emits clean semantic HTML;
// unknown classes fall through to extractDefault (text-preserving).
//
// Coverage: 19 block-class signatures observed across 3 Notion blogs
// (async-grpo, ppo-grpo-cispo, full-stack-transformer-inference).
// Probe scripts in scripts/clipper-test/diagnose-notion-*.mjs.
// ============================================================================

function rubienEscapeHTML(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// URL-scheme allow-list. Notion-extracted content goes directly into the
// reader's #article-content without additional sanitization, so we reject
// dangerous schemes here. Returns the URL string if safe, null otherwise.
function rubienSafeHref(raw) {
  const s = String(raw || '').trim();
  if (!s) return null;
  // Relative paths (start with /, ?, #, ./, ../)
  if (/^[/?#]/.test(s) || /^\.\.?\//.test(s)) return s;
  if (/^(https?|mailto|tel):/i.test(s)) return s;
  return null;
}

// Resolve a (possibly relative) URL to absolute against the current page's
// origin. Used for image src and link href — when the extracted content
// is loaded into the reader (different origin), relative URLs would
// resolve against the reader's bundle URL, not against the source page.
// Notion specifically serves images via relative URLs like
// `/image/attachment%3A...?width=1410` where the width query param
// is critical for high-res CDN delivery.
function rubienResolveURL(raw) {
  const s = rubienSafeHref(raw);
  if (!s) return null;
  if (/^(https?|mailto|tel):/i.test(s)) return s; // already absolute
  // Anchor-only links don't need resolution (they're page-local in the
  // reader context — well, they're broken but that's a separate problem).
  if (s.startsWith('#')) return s;
  try { return new URL(s, location.href).href; } catch (_) { return s; }
}

function rubienLeafOf(block) {
  return block.querySelector('[data-content-editable-leaf="true"]');
}

function rubienClassifyBlock(block) {
  const cls = block.className || '';
  // Order matters where one class name is a substring of another. Verified
  // for the current 19 classes: no full-name substring overlaps. Defensive
  // ordering (most-specific first) anyway: sub_sub_header before sub_header
  // before header; column_list before column.
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

function rubienExtractInline(leaf) {
  if (!leaf) return '';
  const out = [];
  for (const node of leaf.childNodes) {
    if (node.nodeType === 3 /* TEXT_NODE */) {
      out.push(rubienEscapeHTML(node.nodeValue || ''));
      continue;
    }
    if (node.nodeType !== 1 /* ELEMENT_NODE */) continue;
    const el = node;
    const cls = (typeof el.className === 'string') ? el.className : '';

    // Inline code (Notion uses a <div> with this class but it lays out
    // inline via CSS; here we emit a real inline <code>).
    if (cls.indexOf('notion-inline-code-container') >= 0) {
      out.push('<code>' + rubienEscapeHTML(el.textContent || '') + '</code>');
      continue;
    }

    // Inline math: <span class="notion-text-equation-token"> wrapping
    // .katex → .katex-mathml → <math><semantics>...
    // <annotation encoding="application/x-tex">SRC</annotation>. Synthesize
    // `<math data-latex="SRC">` so the reader's renderMath() Pass 1
    // re-renders via bundled KaTeX (which preserves \textcolor).
    if (cls.indexOf('notion-text-equation-token') >= 0) {
      const annotation = el.querySelector('annotation[encoding="application/x-tex"]');
      const latex = annotation ? (annotation.textContent || '') : '';
      if (latex) {
        out.push('<math data-latex="' + rubienEscapeHTML(latex) + '"></math>');
        continue;
      }
      // Fallback: preserve the katex span verbatim if no annotation found.
      const katex = el.querySelector('.katex');
      if (katex) { out.push(katex.outerHTML); continue; }
    }

    // Real links — validate scheme + resolve relative URLs against the
    // source page's origin so clicks land on notion.site, not the reader.
    if (el.tagName === 'A') {
      const href = rubienResolveURL(el.getAttribute('href') || '');
      if (href) {
        out.push('<a href="' + rubienEscapeHTML(href) + '">' + rubienExtractInline(el) + '</a>');
      } else {
        out.push(rubienExtractInline(el));
      }
      continue;
    }

    // Semantic inline tags
    if (['STRONG', 'B', 'EM', 'I', 'U', 'S', 'CODE'].indexOf(el.tagName) >= 0) {
      const tag = el.tagName.toLowerCase();
      out.push('<' + tag + '>' + rubienExtractInline(el) + '</' + tag + '>');
      continue;
    }

    // Notion encodes bold/italic via inline style on wrapping <span>.
    // Combine both wrappers when both styles are set — earlier code used
    // if/else and silently lost the italic on bold-italic spans.
    const style = el.getAttribute('style') || '';
    const isBold = /font-weight\s*:\s*(bold|[6-9]\d\d)/i.test(style);
    const isItalic = /font-style\s*:\s*italic/i.test(style);
    if (isBold || isItalic) {
      let inner = rubienExtractInline(el);
      if (isItalic) inner = '<em>' + inner + '</em>';
      if (isBold) inner = '<strong>' + inner + '</strong>';
      out.push(inner);
      continue;
    }

    // Default: drop the wrapping element, recurse into children.
    out.push(rubienExtractInline(el));
  }
  return out.join('');
}

function rubienExtractCodeBlock(block) {
  // The outer wrapper carries data-block-id; line-numbers sibling has the
  // text in a [data-content-editable-leaf=true]. textContent preserves \n
  // because Notion encodes line breaks inside span textContent.
  const leaf = rubienLeafOf(block);
  const codeText = leaf ? (leaf.textContent || '') : '';
  if (!codeText) return '';
  return '<pre><code>' + rubienEscapeHTML(codeText) + '</code></pre>';
}

function rubienExtractListItem(block) {
  const leaf = rubienLeafOf(block);
  return '<li>' + (leaf ? rubienExtractInline(leaf) : '') + '</li>';
}

function rubienExtractEquationBlock(block) {
  // Notion server-renders block equations via temml. Synthesize
  // <math display="block" data-latex="SRC"> from the inner <annotation>
  // so reader's renderMath() Pass 1 re-renders via KaTeX (preserves
  // \textcolor — temml drops it during MathML conversion).
  const annotation = block.querySelector('annotation[encoding="application/x-tex"]');
  if (annotation) {
    const latex = annotation.textContent || '';
    if (latex) return '<math display="block" data-latex="' + rubienEscapeHTML(latex) + '"></math>';
  }
  const katex = block.querySelector('.katex');
  if (katex) return '<div class="rubien-equation-block">' + katex.outerHTML + '</div>';
  return '<p>' + rubienEscapeHTML(block.textContent || '') + '</p>';
}

function rubienExtractImage(block) {
  const img = block.querySelector('img');
  if (!img) return '';
  const rawSrc = img.getAttribute('src') || img.getAttribute('data-src') || '';
  // Resolve relative URLs to absolute — Notion uses relative paths like
  // `/image/attachment%3A...?width=1410` where the width param is what
  // tells Notion's CDN to serve a high-res variant. Resolving against
  // the reader's bundle URL would 404; we need the source-page origin.
  const src = rubienResolveURL(rawSrc);
  if (!src) return '';
  const alt = img.getAttribute('alt') || '';
  let figcaption = '';
  const caption = block.querySelector('[data-content-editable-leaf="true"]');
  if (caption && caption.textContent && caption.textContent.trim()) {
    figcaption = '<figcaption>' + rubienExtractInline(caption) + '</figcaption>';
  }
  // Inline style ensures the image fills the reader column at natural
  // aspect ratio. Notion's own width/height attrs are pixel-locked to
  // the source page's column width, which is wrong for the reader.
  return '<figure><img src="' + rubienEscapeHTML(src) + '" alt="' + rubienEscapeHTML(alt) +
    '" style="max-width: 100%; height: auto;">' + figcaption + '</figure>';
}

function rubienExtractTable(block) {
  // Notion table-block contains a real <table>. Reuse it but strip styling
  // and sanitize all URL-bearing + event-handler attributes. The cloned
  // outerHTML goes straight into the reader without further sanitization.
  const t = block.querySelector('table');
  if (!t) return '';
  const clone = t.cloneNode(true);
  // querySelectorAll('*') excludes the root, so include `clone` itself
  // explicitly — otherwise the <table>'s own style/class/on*/href survive.
  const all = [clone, ...clone.querySelectorAll('*')];
  for (const el of all) {
    el.removeAttribute('style');
    el.removeAttribute('class');
    // Drop all on* event-handler attributes
    const toRemove = [];
    for (const attr of el.attributes) {
      if (/^on/i.test(attr.name)) toRemove.push(attr.name);
    }
    for (const name of toRemove) el.removeAttribute(name);
    // Sanitize href, src, xlink:href: validate scheme + resolve relative
    // URLs to absolute against the source page's origin.
    for (const name of ['href', 'src', 'xlink:href']) {
      if (el.hasAttribute(name)) {
        const safe = rubienResolveURL(el.getAttribute(name));
        if (safe) el.setAttribute(name, safe);
        else el.removeAttribute(name);
      }
    }
    // srcset is comma-separated "url descriptor" pairs
    if (el.hasAttribute('srcset')) {
      const raw = el.getAttribute('srcset') || '';
      const safeParts = raw.split(',').map((part) => {
        const trimmed = part.trim();
        if (!trimmed) return null;
        const spaceIdx = trimmed.search(/\s/);
        const url = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx);
        const descriptor = spaceIdx === -1 ? '' : trimmed.slice(spaceIdx);
        const safe = rubienResolveURL(url);
        return safe ? safe + descriptor : null;
      }).filter(Boolean);
      if (safeParts.length) el.setAttribute('srcset', safeParts.join(', '));
      else el.removeAttribute('srcset');
    }
  }
  return clone.outerHTML;
}

function rubienExtractDefault(block) {
  // Unknown block type — preserve the text in a div so nothing is silently
  // lost. data-notion-classes lets follow-up handlers identify what to add.
  return '<div class="rubien-notion-unknown" data-notion-classes="' +
    rubienEscapeHTML(block.className || '') + '">' +
    rubienEscapeHTML(block.textContent || '') + '</div>';
}

// Walk DIRECT child [data-block-id] elements of `container` and dispatch
// each through the normal dispatcher (with list-grouping support). Used by
// toggle, callout, column. closest('[data-block-id]') climbs through
// intermediate layout divs without their own data-block-id.
function rubienWalkChildBlocks(container) {
  const children = Array.from(container.querySelectorAll('[data-block-id]'))
    .filter((b) => b.parentElement && b.parentElement.closest('[data-block-id]') === container);
  const out = [];
  let i = 0;
  while (i < children.length) {
    const c = children[i];
    const type = rubienClassifyBlock(c);
    if (type === 'bulleted_list' || type === 'numbered_list') {
      const tag = type === 'bulleted_list' ? 'ul' : 'ol';
      const items = [];
      while (i < children.length && rubienClassifyBlock(children[i]) === type) {
        items.push(rubienExtractListItem(children[i]));
        i++;
      }
      out.push('<' + tag + '>' + items.join('') + '</' + tag + '>');
      continue;
    }
    const html = rubienExtractBlock(c, type);
    if (html) out.push(html);
    i++;
  }
  return out.join('\n');
}

function rubienExtractToggle(block) {
  const leaf = rubienLeafOf(block);
  const label = leaf ? rubienExtractInline(leaf) : '';
  // Children should be DOM-present because the wrapper pre-expanded all
  // toggles before cloning. If pre-expansion failed, the <details> still
  // renders with just the label visible.
  const body = rubienWalkChildBlocks(block);
  return '<details open><summary>' + label + '</summary>' + body + '</details>';
}

function rubienExtractCallout(block) {
  // Icon lives directly under the callout (typically `.notion-record-icon`
  // or the page-emoji span). The broader `[role="img"]` would match any
  // nested role=img inside the callout body — wrong icon.
  let icon = '';
  const iconHost = block.querySelector('.notion-record-icon, .notion-page-icon-wrapper');
  if (iconHost) icon = (iconHost.textContent || '').trim();
  const leaf = rubienLeafOf(block);
  const body = leaf ? rubienExtractInline(leaf) : '';
  const nested = rubienWalkChildBlocks(block);
  const inner = (icon ? '<span class="rubien-notion-callout-icon">' + rubienEscapeHTML(icon) + '</span> ' : '') +
                body + (nested ? nested : '');
  return '<aside class="rubien-notion-callout">' + inner + '</aside>';
}

function rubienExtractQuote(block) {
  const leaf = rubienLeafOf(block);
  return '<blockquote>' + (leaf ? rubienExtractInline(leaf) : '') + '</blockquote>';
}

function rubienExtractColumnList(block) {
  // Readers don't have horizontal real estate; stack columns vertically by
  // walking each column's children inline. No outer wrapper.
  const cols = Array.from(block.querySelectorAll('div.notion-column-block[data-block-id]'))
    .filter((c) => c.parentElement && c.parentElement.closest('[data-block-id]') === block);
  return cols.map((c) => rubienWalkChildBlocks(c)).filter((s) => s).join('\n');
}

function rubienExtractColumn(block) {
  // Reached only if a stray column-block appears without its column_list
  // wrapper (shouldn't happen in practice).
  return rubienWalkChildBlocks(block);
}

function rubienExtractEmbed(block) {
  const iframe = block.querySelector('iframe');
  const rawSrc = iframe ? (iframe.getAttribute('src') || '') : '';
  const src = rubienResolveURL(rawSrc);
  if (src) {
    return '<div class="rubien-notion-embed">[Embed: <a href="' + rubienEscapeHTML(src) + '">' + rubienEscapeHTML(src) + '</a>]</div>';
  }
  const text = (block.textContent || '').trim();
  return '<div class="rubien-notion-embed">[Embed' + (text ? ': ' + rubienEscapeHTML(text.slice(0, 200)) : '') + ']</div>';
}

function rubienExtractBlock(block, type) {
  switch (type) {
    case 'page':           return ''; // title surfaced via payload.title
    case 'text':           return '<p>' + rubienExtractInline(rubienLeafOf(block)) + '</p>';
    case 'h2':             return '<h2>' + rubienExtractInline(rubienLeafOf(block)) + '</h2>';
    case 'h3':             return '<h3>' + rubienExtractInline(rubienLeafOf(block)) + '</h3>';
    case 'h4':             return '<h4>' + rubienExtractInline(rubienLeafOf(block)) + '</h4>';
    case 'code':           return rubienExtractCodeBlock(block);
    case 'equation_block': return rubienExtractEquationBlock(block);
    case 'image':          return rubienExtractImage(block);
    case 'table':          return rubienExtractTable(block);
    case 'toc':            return ''; // reader-generated metadata, not content
    case 'divider':        return '<hr>';
    case 'toggle':         return rubienExtractToggle(block);
    case 'callout':        return rubienExtractCallout(block);
    case 'quote':          return rubienExtractQuote(block);
    case 'column_list':    return rubienExtractColumnList(block);
    case 'column':         return rubienExtractColumn(block);
    case 'embed':          return rubienExtractEmbed(block);
    case 'unknown':        return rubienExtractDefault(block);
  }
  return '';
}

function extractNotionPage(doc) {
  let host = '';
  try { host = (location.hostname || '').toLowerCase(); } catch (_) { return null; }
  const isNotionHost =
    host === 'notion.site' || host.endsWith('.notion.site') ||
    host === 'notion.so'   || host.endsWith('.notion.so');
  if (!isNotionHost) return null;

  const blocks = Array.from(doc.querySelectorAll('[data-block-id]'));
  if (blocks.length === 0) return null;

  // Top-level blocks: parent doesn't have a data-block-id ancestor.
  const topLevel = blocks.filter(
    (b) => !b.parentElement || !b.parentElement.closest('[data-block-id]')
  );

  // Pull the page title out of notion-page-block (or null). Notion's
  // <title> tag is always "Notion" — Defuddle's title extraction is wrong
  // for Notion clips by default. We override payload.title with this.
  let pageTitle = null;
  for (let i = 0; i < topLevel.length; i++) {
    if (rubienClassifyBlock(topLevel[i]) === 'page') {
      const leaf = rubienLeafOf(topLevel[i]);
      pageTitle = leaf ? (leaf.textContent || '').trim() : null;
      break;
    }
  }

  const out = [];
  let i = 0;
  while (i < topLevel.length) {
    const block = topLevel[i];
    const type = rubienClassifyBlock(block);
    if (type === 'bulleted_list' || type === 'numbered_list') {
      const tag = type === 'bulleted_list' ? 'ul' : 'ol';
      const items = [];
      while (i < topLevel.length && rubienClassifyBlock(topLevel[i]) === type) {
        items.push(rubienExtractListItem(topLevel[i]));
        i++;
      }
      out.push('<' + tag + '>' + items.join('') + '</' + tag + '>');
      continue;
    }
    const html = rubienExtractBlock(block, type);
    if (html) out.push(html);
    i++;
  }

  return { content: out.join('\n'), title: pageTitle };
}

function buildPayload(result, error) {
  if (error) {
    return {
      source: SOURCE,
      ok: false,
      error: String(error && error.message ? error.message : error),
    };
  }
  const content = (result && result.content) ? result.content : '';
  return {
    source: SOURCE,
    ok: content.trim().length > 0,
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

window.RubienDefuddleExtract = function RubienDefuddleExtract() {
  // Cache once per extraction — handler refs and URL are read on every
  // phase post (extract_start, parse_async_begin, parse_async_end, exit)
  // and on result delivery. Avoids re-walking `window.webkit.messageHandlers`
  // 5–7 times per clip.
  const mh =
    (typeof window !== 'undefined' && window.webkit && window.webkit.messageHandlers) || null;
  const dbgCh = mh && mh.RubienClipperDebug;
  const resCh = mh && mh.readerResult;
  const pageURL = (typeof document !== 'undefined' && document.URL) || '';

  function debugPost(phase, detail) {
    if (!dbgCh) return;
    try {
      dbgCh.postMessage({
        phase,
        url: pageURL,
        detail: detail == null ? '' : String(detail),
      });
    } catch (_) {}
  }

  function postResult(payload) {
    if (resCh) {
      try { resCh.postMessage(payload); } catch (_) {}
    }
    return JSON.stringify(payload);
  }

  // Idempotency guard: protects against double-injection of this IIFE,
  // duplicate WKScriptMessageHandler delivery, and future code changes
  // that might race the Promise.race below. Mirrors Swift's
  // `defuddleResultHandled` (ReaderExtractionManager.swift:27).
  let delivered = false;
  function deliver(payload) {
    if (delivered) return JSON.stringify(payload);
    delivered = true;
    return postResult(payload);
  }

  function exitError(prefix, err) {
    debugPost('rubien_defuddle_exit', prefix + (err && err.message));
    return deliver(buildPayload(null, err));
  }

  // Notion's React app lazy-renders toggle children only when expanded;
  // clicking the disclosure button on the LIVE document (NOT the clone —
  // React state is bound to the live DOM) reveals them. Iterative loop
  // handles nested lazy toggles; two-consecutive-empty confirmation
  // defends against late re-renders racing the re-query.
  async function preExpandNotionToggles() {
    let host = '';
    try { host = (location.hostname || '').toLowerCase(); } catch (_) { return; }
    const isNotion =
      host === 'notion.site' || host.endsWith('.notion.site') ||
      host === 'notion.so'   || host.endsWith('.notion.so');
    if (!isNotion) return;

    const MAX_PASSES = 10;
    const WAIT_MS = 500;
    // Only target the toggle's own disclosure button — not any descendant
    // role=button inside an expanded toggle's content. The `> div` ancestor
    // anchors us to the toggle's own direct-child wrapper.
    const SELECTOR = 'div.notion-toggle-block > div [aria-expanded="false"][role="button"]:not(a):not([href])';

    // Fast path: zero toggles on the page → skip immediately. The
    // two-consecutive-empty confirmation only matters AFTER expansion
    // (to defend against late renders revealing more lazy toggles).
    // Skipping the wait here keeps non-toggle pages fast. Swift's
    // safety-net timer (8s, ReaderExtractionManager.swift) covers the
    // slow path on pages that DO have toggles to expand.
    if (document.querySelectorAll(SELECTOR).length === 0) return;

    let totalExpanded = 0;
    let consecutiveEmpty = 0;
    for (let pass = 0; pass < MAX_PASSES; pass++) {
      const buttons = document.querySelectorAll(SELECTOR);
      if (buttons.length === 0) {
        consecutiveEmpty++;
        if (consecutiveEmpty >= 2) break;
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
    if (totalExpanded > 0) {
      debugPost('rubien_defuddle_notion_toggles_expanded', 'count=' + totalExpanded);
    }
  }

  // Outer function stays SYNC so `evaluateJavaScript` receives undefined
  // (Swift's processDefuddleJSONFallback in ReaderExtractionManager.swift
  // is guarded by `defuddleResultHandled` — postMessage wins the race in
  // practice). Async work runs inside this IIFE.
  (async () => {
    try {
      debugPost('rubien_defuddle_extract_start');

      await preExpandNotionToggles();

      // Run the unified Notion extractor on a cloned document (avoids
      // React reconciliation). Falls back to Defuddle-only on non-Notion
      // hosts (extractNotionPage returns null after host gate).
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
      }

      // Apply Notion extraction on top of a Defuddle payload, but only when
      // it actually contributed content — empty Notion output (e.g. host
      // gate rejected, or page had zero blocks) must NOT clobber Defuddle's
      // valid result.
      function mergeNotionInto(payload) {
        if (notionExtract == null) return payload;
        const trimmed = notionExtract.content.trim();
        if (trimmed.length === 0) return payload;
        payload.content = notionExtract.content;
        payload.ok = true;
        if (notionExtract.title) payload.title = notionExtract.title;
        return payload;
      }

      let inst;
      try {
        inst = new Defuddle(workingDoc, { url: pageURL });
      } catch (err) {
        // Defuddle constructor failed (rare). If Notion extraction
        // succeeded, deliver THAT — it's a complete content path that
        // doesn't depend on Defuddle's metadata pipeline.
        if (notionExtract != null && notionExtract.content.trim().length > 0) {
          const fallback = buildPayload(null, null);
          fallback.content = notionExtract.content;
          fallback.ok = true;
          if (notionExtract.title) fallback.title = notionExtract.title;
          debugPost('rubien_defuddle_exit', 'ok=true ctor_failed=' + (err && err.message));
          deliver(fallback);
          return;
        }
        exitError('ctor_error: ', err);
        return;
      }

      // Always prefer parseAsync (Defuddle 0.18.1 always exposes it);
      // sync .parse() is a defensive fallback for older Defuddle builds.
      if (typeof inst.parseAsync === 'function') {
        debugPost('rubien_defuddle_parse_async_begin');
        let timer;
        const timeout = new Promise((_, reject) => {
          timer = setTimeout(
            () => reject(new Error('parse_timeout_' + PARSE_TIMEOUT_MS + 'ms')),
            PARSE_TIMEOUT_MS
          );
        });
        try {
          const result = await Promise.race([inst.parseAsync(), timeout]);
          clearTimeout(timer);
          debugPost('rubien_defuddle_parse_async_end');
          const payload = mergeNotionInto(buildPayload(result, null));
          debugPost('rubien_defuddle_exit', 'ok=' + payload.ok);
          deliver(payload);
        } catch (err) {
          clearTimeout(timer);
          exitError('error: ', err);
        }
        return;
      }

      try {
        const result = inst.parse();
        const payload = mergeNotionInto(buildPayload(result, null));
        debugPost('rubien_defuddle_exit', 'ok=' + payload.ok);
        deliver(payload);
      } catch (err) {
        exitError('error: ', err);
      }
    } catch (err) {
      // Last-resort catch — exitError itself shouldn't throw, but if it
      // does the unhandled rejection would be logged by the WKWebView.
      try { exitError('uncaught: ', err); } catch (_) {}
    }
  })();

  return undefined;
};
