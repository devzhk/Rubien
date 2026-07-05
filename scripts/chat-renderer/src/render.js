// render.js — PURE, importable markdown → safe-HTML pipeline.
//
// Runs in BOTH the browser (real DOM) and Node tests (jsdom-backed DOMPurify).
// The security contract (design §3, §5.2):
//   1. `marked` with raw HTML NEUTRALIZED — a literal `<script>` / `<b>` in the
//      source renders as visible, escaped TEXT, never as live HTML. This is done
//      by overriding the renderer's `html` token handler to HTML-escape the raw
//      markup instead of emitting it verbatim (both block- and inline-level HTML
//      tokens route through `renderer.html` in marked v15).
//   2. Every string marked produces is passed through DOMPurify (pinned 3.4.11)
//      before it can reach `innerHTML`. The DOMPurify config forbids
//      script/style/iframe/object/embed, strips every `on*` handler attribute,
//      and only lets `https:` / `http:` URIs live — so `javascript:`, `file:`,
//      `data:`, `mailto:` (and any other scheme) links can never be clickable.
//
// Never assign the output of `marked` directly to innerHTML — always through
// `renderMarkdown`, which is the only export that produces insertion-ready HTML.

import { Marked } from 'marked'
import createDOMPurify from 'dompurify'

// --- HTML escaping (used to neutralize raw HTML tokens) -----------------------

function escapeHTML(input) {
  return String(input ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

// --- marked instance with raw HTML disabled -----------------------------------
// Isolated instance (`new Marked`) so we never mutate any global marked config a
// sibling module might rely on.

const marked = new Marked({ gfm: true, breaks: false })

marked.use({
  renderer: {
    // Neutralize BOTH block-level and inline raw HTML tokens: emit the source as
    // escaped text. `arg` is a token object in marked v15 ({ text, raw, ... });
    // older shapes passed a bare string — handle both defensively.
    html(arg) {
      const raw = typeof arg === 'string' ? arg : arg?.text ?? arg?.raw ?? ''
      // Non-empty escaped output is truthy, so marked won't fall back to the
      // default (verbatim) renderer.
      return escapeHTML(raw) || '&#8203;'
    },
  },
})

// --- DOMPurify (cross-environment) --------------------------------------------
// In the browser the module-global `window` is used automatically. Node tests
// inject a jsdom window via `useDOMWindow(win)` BEFORE calling `renderMarkdown`.

const SANITIZE_CONFIG = {
  // Redundant with DOMPurify defaults for script, but explicit per the threat
  // model — never let these tags materialize as live elements.
  FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'base', 'meta', 'link'],
  // Only http/https URIs survive on href/src — the contract's live-link set.
  // `javascript:`, `file:`, `data:`, `mailto:` (and any custom scheme) are
  // stripped, so such links are inert.
  ALLOWED_URI_REGEXP: /^https?:/i,
  // Keep it a string we can hand to innerHTML.
  RETURN_DOM: false,
  RETURN_DOM_FRAGMENT: false,
}

let purifier = null

function installHooks(instance) {
  // Belt-and-suspenders: drop EVERY attribute whose name starts with `on`
  // (case-insensitive) so no event handler can ever survive, independent of the
  // DOMPurify version's built-in list.
  instance.addHook('uponSanitizeAttribute', (_node, data) => {
    const name = (data.attrName || '').toLowerCase()
    if (name.startsWith('on')) {
      data.keepAttr = false
    }
  })
  return instance
}

/**
 * Inject the DOM `window` DOMPurify should bind to. Required in Node/jsdom tests;
 * optional in the browser (the global `window` is used lazily otherwise).
 * @param {object} win a `window`-like object (jsdom `.window` under test)
 */
export function useDOMWindow(win) {
  purifier = installHooks(createDOMPurify(win))
  return purifier
}

function getPurifier() {
  if (purifier) return purifier
  if (typeof window !== 'undefined' && window.document) {
    purifier = installHooks(createDOMPurify(window))
    return purifier
  }
  throw new Error('render.js: no DOM window available — call useDOMWindow(win) first')
}

/**
 * Render untrusted markdown to a sanitized HTML string safe for `innerHTML`.
 * Raw HTML in the source is escaped to visible text; the result is DOMPurified.
 * @param {string} md markdown source (may be hostile)
 * @returns {string} insertion-ready, sanitized HTML
 */
export function renderMarkdown(md) {
  const rawHTML = marked.parse(md ?? '', { async: false })
  return getPurifier().sanitize(rawHTML, SANITIZE_CONFIG)
}
