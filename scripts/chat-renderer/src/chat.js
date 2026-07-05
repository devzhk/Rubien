// chat.js — browser entry. Installs `window.RubienChat` (the Swift ↔ JS contract)
// and drives the transcript DOM. All model/user content flows through
// `renderMarkdown` (raw HTML off + DOMPurify) before it ever touches innerHTML.
//
// KaTeX (`renderMathInElement`, from the inlined auto-render.min.js) runs ONLY on
// a full/commit render — never mid-stream — to avoid half-formula flicker.

import { renderMarkdown, useDOMWindow } from './render.js'
import './chat.css'

// --- Swift bridge -------------------------------------------------------------

function post(name, body) {
  try {
    window.webkit?.messageHandlers?.[name]?.postMessage(body ?? {})
  } catch (_) {
    /* not running inside WKWebView (e.g. debug harness) */
  }
}

// --- Transcript state ---------------------------------------------------------

let transcript = null
// The currently open assistant bubble that streaming deltas target.
let streaming = null // { root, body } | null
let streamingRaw = '' // accumulated markdown for the open bubble
let rafHandle = null

// --- KaTeX --------------------------------------------------------------------

const KATEX_OPTIONS = {
  delimiters: [
    { left: '$$', right: '$$', display: true },
    { left: '$', right: '$', display: false },
    { left: '\\(', right: '\\)', display: false },
    { left: '\\[', right: '\\]', display: true },
  ],
  throwOnError: false,
  // Security: KaTeX output is inserted AFTER DOMPurify, so keep KaTeX itself
  // incapable of emitting dangerous markup. `trust:false` (the default, pinned
  // explicitly) refuses \href / \htmlClass / \includegraphics etc. from
  // untrusted LaTeX source — so a hostile `$\href{javascript:…}{x}$` produces
  // no live link. Covered by test/integration.test.js.
  trust: false,
  ignoredClasses: ['katex'],
}

function typeset(el) {
  if (!el || typeof window.renderMathInElement !== 'function') return
  try {
    window.renderMathInElement(el, KATEX_OPTIONS)
  } catch (_) {
    /* throwOnError:false already guards per-formula; swallow any global slip */
  }
}

// --- DOM helpers --------------------------------------------------------------

function makeBubble(role) {
  const root = document.createElement('div')
  root.className = `chat-msg chat-msg-${role}`
  const body = document.createElement('div')
  body.className = 'chat-bubble'
  root.appendChild(body)
  return { root, body }
}

function makeNotice() {
  const root = document.createElement('div')
  root.className = 'chat-notice'
  return { root, body: root }
}

function applyTurnStatus(root, turnStatus) {
  if (turnStatus !== 'interrupted' && turnStatus !== 'denied') return
  const line = document.createElement('div')
  line.className = `chat-turn-status chat-turn-${turnStatus}`
  line.textContent = turnStatus === 'interrupted' ? 'Interrupted' : 'Denied'
  root.appendChild(line)
}

function makeToolChip(chip) {
  const name = String(chip?.name ?? 'tool')
  const detail = chip?.detail == null ? '' : String(chip.detail)
  const status = chip?.status === 'completed' || chip?.status === 'denied' ? chip.status : 'started'

  const root = document.createElement('details')
  root.className = `chat-tool-chip chat-tool-${status}`

  const summary = document.createElement('summary')
  const dot = document.createElement('span')
  dot.className = 'chat-tool-dot'
  const label = document.createElement('span')
  label.className = 'chat-tool-name'
  label.textContent = name // textContent — never HTML
  const badge = document.createElement('span')
  badge.className = 'chat-tool-badge'
  badge.textContent = status
  summary.appendChild(dot)
  summary.appendChild(label)
  summary.appendChild(badge)
  root.appendChild(summary)

  if (detail) {
    const d = document.createElement('div')
    d.className = 'chat-tool-detail'
    d.textContent = detail // textContent — never HTML
    root.appendChild(d)
  }
  return root
}

// Wrap each <pre> in a copy-button affordance. Idempotent (guarded), and only
// invoked on full/commit renders — not per streaming frame.
function enhanceCodeBlocks(container) {
  const pres = container.querySelectorAll('pre')
  pres.forEach((pre) => {
    if (pre.parentElement && pre.parentElement.classList.contains('chat-codeblock')) return
    const wrap = document.createElement('div')
    wrap.className = 'chat-codeblock'
    pre.parentNode.insertBefore(wrap, pre)
    wrap.appendChild(pre)
    const btn = document.createElement('button')
    btn.type = 'button'
    btn.className = 'chat-copy-btn'
    btn.textContent = 'Copy'
    wrap.appendChild(btn)
  })
}

// TODO(phase-2): unconditionally pins to the bottom — a user scrolling up to
// re-read during a long stream gets yanked back down every frame. When the real
// sidebar replaces the debug harness, only auto-scroll when already near bottom.
function scrollToBottom() {
  if (!transcript) return
  transcript.scrollTop = transcript.scrollHeight
}

// --- Rendering ----------------------------------------------------------------

// Full render of trusted-markdown-source into a body element: sanitize, wire
// code blocks. `runKaTeX` gates math typesetting (user/assistant only).
function renderFull(bodyEl, markdown, runKaTeX) {
  bodyEl.innerHTML = renderMarkdown(markdown) // sanitized string only
  enhanceCodeBlocks(bodyEl)
  if (runKaTeX) typeset(bodyEl)
}

function cancelPendingRender() {
  if (rafHandle != null) {
    cancelAnimationFrame(rafHandle)
    rafHandle = null
  }
}

// rAF-throttled streaming re-render: markdown → sanitize only. No KaTeX, no
// code-block enhancement (both wait for commit).
// TODO(phase-2): re-parses the FULL accumulated buffer every frame → O(n²) over
// a long streamed answer (rAF bounds frequency, not per-render cost). Fine for
// typical chat lengths; if long-answer streaming feels janky, throttle to
// ~50-100ms or append deltas as text past N KB — commit always does the
// authoritative full render anyway.
function scheduleStreamRender() {
  if (rafHandle != null) return
  rafHandle = requestAnimationFrame(() => {
    rafHandle = null
    if (streaming) {
      streaming.body.innerHTML = renderMarkdown(streamingRaw)
      scrollToBottom()
    }
  })
}

function appendRecord(m) {
  const role = m?.role
  if (role === 'tool') {
    let chip
    try {
      chip = JSON.parse(m?.body ?? '{}')
    } catch (_) {
      chip = { name: 'tool', detail: String(m?.body ?? ''), status: 'started' }
    }
    transcript.appendChild(makeToolChip(chip))
    return
  }
  if (role === 'notice') {
    const n = makeNotice()
    n.body.innerHTML = renderMarkdown(m?.body ?? '')
    transcript.appendChild(n.root)
    return
  }
  // user | assistant (default)
  const uiRole = role === 'user' ? 'user' : 'assistant'
  const bubble = makeBubble(uiRole)
  renderFull(bubble.body, m?.body ?? '', /* runKaTeX */ true)
  applyTurnStatus(bubble.root, m?.turnStatus)
  transcript.appendChild(bubble.root)
}

// --- window.RubienChat (Swift contract) ---------------------------------------

const RubienChat = {
  reset() {
    cancelPendingRender()
    streaming = null
    streamingRaw = ''
    if (transcript) transcript.innerHTML = ''
  },

  loadTranscript(messages) {
    this.reset()
    const list = Array.isArray(messages) ? messages.slice() : []
    // Deterministic order by seq when present; stable otherwise.
    list.sort((a, b) => (Number(a?.seq) || 0) - (Number(b?.seq) || 0))
    for (const m of list) appendRecord(m)
    scrollToBottom()
  },

  addUserMessage(markdown) {
    const bubble = makeBubble('user')
    renderFull(bubble.body, String(markdown ?? ''), /* runKaTeX */ true)
    transcript.appendChild(bubble.root)
    scrollToBottom()
  },

  beginAssistantMessage() {
    cancelPendingRender()
    streaming = makeBubble('assistant')
    streamingRaw = ''
    transcript.appendChild(streaming.root)
    scrollToBottom()
  },

  appendDelta(text) {
    if (!streaming) this.beginAssistantMessage()
    streamingRaw += String(text ?? '')
    scheduleStreamRender() // rAF-throttled; NO KaTeX
  },

  commitAssistantMessage(markdown) {
    if (!streaming) this.beginAssistantMessage()
    cancelPendingRender()
    renderFull(streaming.body, String(markdown ?? ''), /* runKaTeX */ true)
    streaming = null
    streamingRaw = ''
    scrollToBottom()
  },

  addToolChip(chip) {
    transcript.appendChild(makeToolChip(chip || {}))
    scrollToBottom()
  },

  addNotice(markdown) {
    const n = makeNotice()
    n.body.innerHTML = renderMarkdown(String(markdown ?? ''))
    transcript.appendChild(n.root)
    scrollToBottom()
  },

  setTheme(mode) {
    document.documentElement.setAttribute('data-theme', mode === 'dark' ? 'dark' : 'light')
  },
}

// --- Delegated events (links + copy) ------------------------------------------

function installDelegates() {
  transcript.addEventListener('click', (e) => {
    // Copy button on a code block.
    const copyBtn = e.target.closest('.chat-copy-btn')
    if (copyBtn) {
      e.preventDefault()
      const pre = copyBtn.parentElement?.querySelector('pre')
      const code = pre ? pre.textContent : ''
      post('copyCode', { code })
      copyBtn.textContent = 'Copied'
      window.setTimeout(() => {
        copyBtn.textContent = 'Copy'
      }, 1200)
      return
    }
    // Links: only http/https are live (routed to Swift); everything else inert.
    const anchor = e.target.closest('a')
    if (anchor) {
      e.preventDefault() // inert by default
      const href = anchor.getAttribute('href') || ''
      if (/^https?:/i.test(href)) {
        post('openExternalLink', { url: href })
      }
    }
  })
}

// --- Bootstrap ----------------------------------------------------------------

function init() {
  transcript = document.getElementById('transcript')
  if (!transcript) {
    transcript = document.createElement('div')
    transcript.id = 'transcript'
    document.body.appendChild(transcript)
  }
  // Bind DOMPurify to the live window explicitly (also works lazily, but be
  // deterministic).
  useDOMWindow(window)
  installDelegates()

  window.RubienChat = RubienChat

  // Ready handshake — Swift queues all API calls until this fires (mirrors the
  // note-editor's `noteEditorReady`).
  post('chatReady', {})
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init)
} else {
  init()
}
