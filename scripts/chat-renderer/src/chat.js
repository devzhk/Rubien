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

// --- Stick-to-bottom + "new messages" pill ------------------------------------
// The transcript follows the stream ONLY while the user is at the bottom. Once
// they scroll up to re-read, new content no longer yanks their view down — a small
// "N new messages" pill appears instead, and clicking it (or scrolling back to the
// bottom) resumes following.
const NEAR_BOTTOM_PX = 48 // slack so a hair off the bottom still counts as "at bottom"
let stickToBottom = true
let unseenCount = 0 // discrete items added while scrolled up
let streamingCounted = false // has the OPEN assistant bubble been counted as unseen?
let jumpPill = null

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
  // Status is conveyed by the dot color alone (started/completed/denied); the
  // `chat-tool-<status>` class on root carries it for a11y / styling.
  root.dataset.status = status
  summary.appendChild(dot)
  summary.appendChild(label)
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

function scrollToBottom() {
  if (!transcript) return
  transcript.scrollTop = transcript.scrollHeight
}

function isNearBottom() {
  if (!transcript) return true
  return transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight <= NEAR_BOTTOM_PX
}

function updateJumpPill() {
  if (!jumpPill) return
  const show = unseenCount > 0 && !stickToBottom
  jumpPill.textContent = unseenCount === 1 ? '1 new message' : `${unseenCount} new messages`
  jumpPill.classList.toggle('is-visible', show)
}

// New discrete item (tool chip, notice, or a finalized message): follow if the
// user is at the bottom, else bump the pill by one.
function followOrHint(isNewItem) {
  if (stickToBottom) {
    scrollToBottom()
  } else if (isNewItem) {
    unseenCount += 1
    updateJumpPill()
  }
}

// The open assistant bubble grew (begin or a streaming delta): follow if at the
// bottom, else surface the pill ONCE for this reply — whether the user was already
// scrolled up when it began or scrolled up partway through. Idempotent per bubble
// (`streamingCounted`), so a single streamed reply reads as "1 new message".
function followStreaming() {
  if (stickToBottom) {
    scrollToBottom()
  } else if (!streamingCounted) {
    streamingCounted = true
    unseenCount += 1
    updateJumpPill()
  }
}

// Force the view to the latest and resume following (composer send, transcript
// load, or the pill click). Clears the unseen counter.
function jumpToLatest() {
  stickToBottom = true
  unseenCount = 0
  scrollToBottom()
  updateJumpPill()
}

// The user drove the scrollbar: re-derive whether we're following. Reaching the
// bottom clears the pill; scrolling up stops the auto-follow.
function onUserScroll() {
  stickToBottom = isNearBottom()
  if (stickToBottom) unseenCount = 0
  updateJumpPill()
}

// The sidebar is resizable: growing it can bring the bottom into view without any
// scroll event. Keep a following user pinned; otherwise re-derive follow-state (a
// taller viewport may now be "at bottom", clearing a now-stale pill).
function onViewportResize() {
  if (stickToBottom) scrollToBottom()
  else onUserScroll()
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
      followStreaming() // grow the open bubble; pill once if scrolled up
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
    // A fresh conversation follows from the bottom again.
    stickToBottom = true
    unseenCount = 0
    streamingCounted = false
    updateJumpPill()
  },

  loadTranscript(messages) {
    this.reset()
    const list = Array.isArray(messages) ? messages.slice() : []
    // Deterministic order by seq when present; stable otherwise.
    list.sort((a, b) => (Number(a?.seq) || 0) - (Number(b?.seq) || 0))
    for (const m of list) appendRecord(m)
    jumpToLatest()
  },

  addUserMessage(markdown) {
    const bubble = makeBubble('user')
    renderFull(bubble.body, String(markdown ?? ''), /* runKaTeX */ true)
    transcript.appendChild(bubble.root)
    // The user just sent this — always show it and resume following.
    jumpToLatest()
  },

  beginAssistantMessage() {
    cancelPendingRender()
    streaming = makeBubble('assistant')
    streamingRaw = ''
    streamingCounted = false // a new reply — countable once as it grows
    transcript.appendChild(streaming.root)
    followStreaming()
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
    followOrHint(false) // same bubble finalizing — already counted at begin
  },

  addToolChip(chip) {
    transcript.appendChild(makeToolChip(chip || {}))
    followOrHint(true)
  },

  addNotice(markdown) {
    const n = makeNotice()
    n.body.innerHTML = renderMarkdown(String(markdown ?? ''))
    transcript.appendChild(n.root)
    followOrHint(true)
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

  // "N new messages" pill — hidden until content arrives while scrolled up.
  jumpPill = document.createElement('button')
  jumpPill.type = 'button'
  jumpPill.id = 'chat-jump'
  jumpPill.addEventListener('click', jumpToLatest)
  document.body.appendChild(jumpPill)
  // Follow-state tracks the user's own scrolling (passive — never blocks scroll).
  transcript.addEventListener('scroll', onUserScroll, { passive: true })
  // …and a resize of the (resizable) sidebar, which no scroll event covers.
  if (typeof ResizeObserver === 'function') {
    new ResizeObserver(onViewportResize).observe(transcript)
  }
  window.addEventListener('resize', onViewportResize, { passive: true })

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
