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

// --- math passthrough ----------------------------------------------------------
// KaTeX typesets AFTER this pipeline (chat.js runs `renderMathInElement` over the
// sanitized DOM), so formulas must reach the DOM as intact TEXT. Without these
// tokenizers marked destroys TeX first: `\[` / `\(` are CommonMark punctuation
// escapes (→ `[` / `(`), `_` / `**` inside a formula become emphasis, and a bare
// `=` / `-` line under a formula line makes a setext heading. Math is therefore
// tokenized ahead of marked's own rules and re-emitted as escaped text with the
// delimiters NORMALIZED to `\( \)` / `\[ \]` (display environments self-delimit)
// — exactly the MATH_DELIMITERS contract the KaTeX pass scans for. `$` forms are
// normalized away so a stray `$5 and $10` in prose can never be eaten at the DOM
// stage; the tokenizer below is the single gatekeeper for what counts as
// dollar-math.
//
// Fenced code and inline code spans never reach these tokenizers (fences win at
// block level; a code span opens before any `\(` inside it), and the KaTeX pass
// skips <pre>/<code> — so TeX quoted as code stays source text.

// Display environments that carry their own delimiters (KaTeX-supported).
const MATH_DISPLAY_ENVIRONMENTS = [
  'equation', 'equation*', 'align', 'align*', 'alignat', 'alignat*',
  'gather', 'gather*', 'CD',
]

const MATH_ENV_SET = new Set(MATH_DISPLAY_ENVIRONMENTS)

// THE delimiter contract with the KaTeX DOM pass: everything the tokenizers
// below emit, and nothing else, in renderMathInElement's option shape. chat.js
// spreads this into KATEX_OPTIONS — keep it the one source.
export const MATH_DELIMITERS = [
  { left: '\\(', right: '\\)', display: false },
  { left: '\\[', right: '\\]', display: true },
  ...MATH_DISPLAY_ENVIRONMENTS.map((env) => (
    { left: `\\begin{${env}}`, right: `\\end{${env}}`, display: true }
  )),
]

// Display-environment block starting at position 0 of `t`: `{ env, end }` (end
// = index just past `\end{env}`) or null. Opener-first so a non-math
// environment (`\begin{itemize}` in quoted LaTeX) is rejected by the Set check
// alone — never paying a body scan — and the closer is found by indexOf, which
// also keeps a two-env body from reading as one (first closer wins).
function displayEnvAt(t) {
  const open = /^\\begin\{([a-zA-Z]+\*?)\}/.exec(t)
  if (!open || !MATH_ENV_SET.has(open[1])) return null
  const closer = `\\end{${open[1]}}`
  const at = t.indexOf(closer, open[0].length)
  return at === -1 ? null : { env: open[1], end: at + closer.length }
}

// Escaped text the KaTeX DOM pass will recognize. Display environments from the
// contract self-delimit; everything else — including other `\begin{…}` shapes
// like pmatrix, which are only valid inside math mode — is (re)wrapped in the
// normalized pair.
function mathText(tex, display) {
  const t = tex.trim()
  if (displayEnvAt(t)) return escapeHTML(t)
  return escapeHTML(display ? `\\[${t}\\]` : `\\(${t}\\)`)
}

// `$…$` without lookbehind (esbuild targets safari16): first and last content
// chars are non-space and non-`$` (`\$` allowed), no `$` inside, single line,
// and the closer isn't followed by a digit or another `$` — so "costs $5 and
// $10 total" stays prose while `$x$` is math.
const INLINE_DOLLAR = /^\$((?:\\\$|[^\s$])(?:(?:\\\$|[^$\n])*?(?:\\\$|[^\s$]))?)\$(?![$\d])/

const BLOCK_MATH_OPENER = /^ {0,3}(?:\$\$|\\\[|\\begin\{)/m

const blockMath = {
  name: 'blockMath',
  level: 'block',
  start(src) {
    // marked calls this once per paragraph/text step with the WHOLE remaining
    // source; bound the scan to the current paragraph window or math-free prose
    // parses quadratically (and this runs per rAF frame while streaming). An
    // opener past the next blank line belongs to a later block step, which
    // re-scans from its own start.
    const blank = src.indexOf('\n\n')
    const win = blank === -1 ? src : src.slice(0, blank + 2)
    const i = win.search(BLOCK_MATH_OPENER)
    return i === -1 ? undefined : i
  },
  tokenizer(src) {
    let m = /^ {0,3}\$\$([\s\S]+?)\$\$[ \t]*(?:\n|$)/.exec(src)
      || /^ {0,3}\\\[([\s\S]+?)\\\][ \t]*(?:\n|$)/.exec(src)
    if (m) return { type: 'blockMath', raw: m[0], text: m[1] }
    const lead = /^ {0,3}(?=\\begin\{)/.exec(src)
    if (!lead) return undefined
    const body = lead[0].length ? src.slice(lead[0].length) : src
    const d = displayEnvAt(body)
    if (!d) return undefined
    // Only trailing blanks may follow the closer on its line.
    let p = d.end
    while (p < body.length && (body[p] === ' ' || body[p] === '\t')) p += 1
    if (p < body.length && body[p] !== '\n') return undefined
    return {
      type: 'blockMath',
      raw: src.slice(0, lead[0].length + Math.min(p + 1, body.length)),
      text: body.slice(0, d.end),
    }
  },
  renderer(token) {
    return `<p>${mathText(token.text, true)}</p>\n`
  },
}

const inlineMath = {
  name: 'inlineMath',
  level: 'inline',
  start(src) {
    const i = src.search(/\\\(|\\\[|\\begin\{|\$/)
    return i === -1 ? undefined : i
  },
  tokenizer(src) {
    let m = /^\\\(([\s\S]+?)\\\)/.exec(src)
    if (m) return { type: 'inlineMath', raw: m[0], text: m[1], display: false }
    // Display forms mid-paragraph (models often inline them into a sentence).
    m = /^\\\[([\s\S]+?)\\\]/.exec(src) || /^\$\$([\s\S]+?)\$\$/.exec(src)
    if (m) return { type: 'inlineMath', raw: m[0], text: m[1], display: true }
    const d = displayEnvAt(src)
    if (d) {
      const raw = src.slice(0, d.end)
      return { type: 'inlineMath', raw, text: raw, display: true }
    }
    m = INLINE_DOLLAR.exec(src)
    if (m) return { type: 'inlineMath', raw: m[0], text: m[1], display: false }
    return undefined
  },
  renderer(token) {
    return mathText(token.text, token.display)
  },
}

// A fence body that is exactly ONE self-contained display formula → its TeX
// (outer `\[ \]` / `$$ $$` stripped; environments kept whole — they
// self-delimit). Else null. Interior delimiters of the same family reject the
// body, so a fence holding several formulas (or prose between them) keeps its
// code box instead of collapsing into one garbled formula.
function displayFormulaTeX(body) {
  const t = body.trim()
  let m = /^\\\[([\s\S]*)\\\]$/.exec(t)
  if (m) return /\\\[|\\\]/.test(m[1]) ? null : m[1]
  m = /^\$\$([\s\S]*)\$\$$/.exec(t)
  if (m) return m[1].includes('$$') ? null : m[1]
  const d = displayEnvAt(t)
  return d && d.end === t.length ? t : null
}

// --- marked instance with raw HTML disabled -----------------------------------
// Isolated instance (`new Marked`) so we never mutate any global marked config a
// sibling module might rely on.

const marked = new Marked({ gfm: true, breaks: false })

const MATH_FENCE_LANGS = new Set(['math', 'katex'])
const LATEX_FENCE_LANGS = new Set(['latex', 'tex'])

marked.use({
  extensions: [blockMath, inlineMath],
  tokenizer: {
    // Setext headings run BEFORE the paragraph tokenizer ever consults
    // extension start() positions, so "Here is:\n\[\n…\n=\n…\]" would mint an
    // <h1> swallowing the math opener. When the would-be heading contains a
    // block-math opener line, suppress the heading (return a non-token) and let
    // paragraph + blockMath partition the text instead; `false` defers to the
    // default tokenizer.
    lheading(src) {
      const rule = this?.rules?.block?.lheading
      if (!rule) return false
      const cap = rule.exec(src)
      if (cap && BLOCK_MATH_OPENER.test(cap[0])) return undefined
      return false
    },
  },
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
    // Math-flavored fences render as display math, not source boxes: ```math /
    // ```katex always (the GitHub semantic — bare TeX body); ```latex / ```tex
    // only when the body is a single delimited display block (Codex wraps its
    // display math exactly this way). Any other body — a document snippet,
    // several formulas, prose about LaTeX — falls through to the normal code
    // block.
    code(token) {
      const lang = (token.lang || '').trim().split(/\s+/)[0].toLowerCase()
      const body = token.text ?? ''
      let tex = null
      if (MATH_FENCE_LANGS.has(lang)) tex = displayFormulaTeX(body) ?? body
      else if (LATEX_FENCE_LANGS.has(lang)) tex = displayFormulaTeX(body)
      if (tex == null) return false // default fence rendering
      return `<p>${mathText(tex, true)}</p>\n`
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
