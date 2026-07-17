// chat.js — browser entry. Installs `window.RubienChat` (the Swift ↔ JS contract)
// and drives the transcript DOM. All model/user content flows through
// `renderMarkdown` (raw HTML off + DOMPurify) before it ever touches innerHTML.
//
// KaTeX (`renderMathInElement`, from the inlined auto-render.min.js) runs ONLY on
// a full/commit render — never mid-stream — to avoid half-formula flicker.

import { renderMarkdown, useDOMWindow, MATH_DELIMITERS } from './render.js'
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
let toolGroupSequence = 0

// Keep short tool traces fully visible. Once a consecutive run reaches three
// calls, retain the newest call and fold the earlier calls behind a disclosure.
const TOOL_GROUP_COLLAPSE_AFTER = 2

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
  // Exactly the delimiter forms render.js emits: its math tokenizers normalize
  // every `$…$` / `$$…$$` to `\( \)` / `\[ \]` before the DOM stage, so raw `$`
  // is deliberately NOT scanned here — prose like "costs $5 and $10" can never
  // be eaten as math.
  delimiters: MATH_DELIMITERS,
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

function directChildWithClass(root, className) {
  return Array.from(root.children).find((child) => child.classList.contains(className)) ?? null
}

function setToolGroupExpanded(root, expanded) {
  const history = directChildWithClass(root, 'chat-tool-history')
  const toggle = directChildWithClass(root, 'chat-tool-toggle')
  if (!history || !toggle) return

  history.hidden = !expanded
  root.classList.toggle('is-expanded', expanded)
  toggle.setAttribute('aria-expanded', String(expanded))
  const count = history.children.length
  const noun = count === 1 ? 'tool call' : 'tool calls'
  const label = directChildWithClass(toggle, 'chat-tool-toggle-label')
  if (label) label.textContent = expanded ? 'Show fewer tool calls' : `+ ${count} more ${noun}`
  toggle.setAttribute(
    'aria-label',
    expanded ? `Hide ${count} earlier ${noun}` : `Show ${count} earlier ${noun}`,
  )
}

// Expanding inserts history above the newest chip. Preserve the disclosure's
// viewport position across that height change, then refresh follow state so the
// next live event cannot unexpectedly yank a reader who was already scrolled up.
function toggleToolGroup(root, expanded, keyboardInitiated) {
  const toggle = directChildWithClass(root, 'chat-tool-toggle')
  if (!toggle) return
  const topBefore = toggle.getBoundingClientRect().top
  setToolGroupExpanded(root, expanded)
  const topAfter = toggle.getBoundingClientRect().top
  transcript.scrollTop += topAfter - topBefore
  onUserScroll()

  // The revealed summaries precede the disclosure in DOM order. Keyboard and
  // assistive-tech activations enter that content so forward navigation visits
  // every newly revealed tool call before returning to the collapse button. Let
  // focus scroll normally so a long history never leaves keyboard focus offscreen.
  if (expanded && keyboardInitiated) {
    const history = directChildWithClass(root, 'chat-tool-history')
    history?.querySelector('.chat-tool-chip summary')?.focus()
  }
}

function makeToolGroup(earlierChips, latestChip, expanded = false) {
  const root = document.createElement('div')
  root.className = 'chat-tool-group'

  const history = document.createElement('div')
  history.className = 'chat-tool-history'
  history.id = `chat-tool-history-${++toolGroupSequence}`
  for (const chip of earlierChips) history.appendChild(chip)
  root.appendChild(history)

  latestChip.classList.add('chat-tool-latest')
  root.appendChild(latestChip)

  const toggle = document.createElement('button')
  toggle.type = 'button'
  toggle.className = 'chat-tool-toggle'
  toggle.setAttribute('aria-controls', history.id)
  const arrow = document.createElement('span')
  arrow.className = 'chat-tool-toggle-arrow'
  arrow.setAttribute('aria-hidden', 'true')
  const label = document.createElement('span')
  label.className = 'chat-tool-toggle-label'
  toggle.appendChild(arrow)
  toggle.appendChild(label)
  toggle.addEventListener('click', (event) => {
    toggleToolGroup(
      root,
      toggle.getAttribute('aria-expanded') !== 'true',
      event.detail === 0,
    )
  })
  root.appendChild(toggle)

  setToolGroupExpanded(root, expanded)
  return root
}

function appendToolChip(chip) {
  const nextChip = makeToolChip(chip)
  const last = transcript.lastElementChild

  // Extend an existing trailing group without rebuilding it, preserving the
  // user's expanded/collapsed choice while the live turn adds more calls.
  if (last?.classList.contains('chat-tool-group')) {
    const history = directChildWithClass(last, 'chat-tool-history')
    const latest = directChildWithClass(last, 'chat-tool-latest')
    const toggle = directChildWithClass(last, 'chat-tool-toggle')
    if (history && latest && toggle) {
      const focusedElement = latest.contains(document.activeElement) ? document.activeElement : null
      const preserveInteraction = latest.open || focusedElement != null
      const anchor = preserveInteraction ? latest : null
      const topBefore = anchor?.getBoundingClientRect().top
      const wasExpanded = toggle.getAttribute('aria-expanded') === 'true' || preserveInteraction
      latest.classList.remove('chat-tool-latest')
      history.appendChild(latest)
      nextChip.classList.add('chat-tool-latest')
      last.insertBefore(nextChip, toggle)
      setToolGroupExpanded(last, wasExpanded)
      if (anchor && topBefore != null) {
        transcript.scrollTop += anchor.getBoundingClientRect().top - topBefore
        onUserScroll()
      }
      focusedElement?.focus({ preventScroll: true })
      return
    }
  }

  // Direct chips are only left behind for runs of one or two. The next call
  // crosses the threshold, so move that trailing run into a compact group.
  const trailingChips = []
  let cursor = last
  while (cursor?.classList.contains('chat-tool-chip')) {
    trailingChips.unshift(cursor)
    cursor = cursor.previousElementSibling
  }
  if (trailingChips.length >= TOOL_GROUP_COLLAPSE_AFTER) {
    // A live third call must not hide content the user has opened or focused.
    const focusedElement = trailingChips.some((chip) => chip.contains(document.activeElement))
      ? document.activeElement
      : null
    const preserveInteraction = focusedElement != null || trailingChips.some((chip) => chip.open)
    transcript.appendChild(makeToolGroup(trailingChips, nextChip, preserveInteraction))
    // Moving a focused node through the detached group root clears focus in
    // WebKit/jsdom, so restore it once the complete group is back in the DOM.
    focusedElement?.focus({ preventScroll: true })
  } else {
    transcript.appendChild(nextChip)
  }
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

function normalizeUserPayload(value) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return {
      body: String(value.body ?? ''),
      attachments: Array.isArray(value.attachments) ? value.attachments : [],
    }
  }
  return { body: String(value ?? ''), attachments: [] }
}

function formatAttachmentBytes(value) {
  const bytes = Number(value)
  if (!Number.isFinite(bytes) || bytes < 0) return ''
  if (bytes < 1024) return `${Math.round(bytes)} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function makeAttachment(attachment) {
  const kind = attachment?.kind === 'image' ? 'image' : 'text'
  const isAvailable = attachment?.isAvailable === true
  const root = document.createElement('div')
  root.className = `chat-attachment chat-attachment-${kind}`
  if (!isAvailable) root.classList.add('chat-attachment-unavailable')

  const thumbnail = String(attachment?.thumbnailDataURL ?? '')
  if (kind === 'image' && /^data:image\/(?:png|jpeg);base64,[A-Za-z0-9+/]+={0,2}$/.test(thumbnail)) {
    const image = document.createElement('img')
    image.className = 'chat-attachment-thumbnail'
    image.src = thumbnail
    image.alt = ''
    root.appendChild(image)
  } else {
    const icon = document.createElement('span')
    icon.className = 'chat-attachment-icon'
    icon.textContent = kind === 'image' ? 'Image' : 'Text'
    root.appendChild(icon)
  }

  const details = document.createElement('span')
  details.className = 'chat-attachment-details'
  const name = document.createElement('span')
  name.className = 'chat-attachment-name'
  name.textContent = String(attachment?.displayName ?? 'Attachment')
  details.appendChild(name)

  const meta = document.createElement('span')
  meta.className = 'chat-attachment-meta'
  meta.textContent = isAvailable
    ? formatAttachmentBytes(attachment?.byteCount)
    : 'File unavailable'
  details.appendChild(meta)
  root.appendChild(details)
  return root
}

function renderUserPayload(value) {
  const payload = normalizeUserPayload(value)
  const bubble = makeBubble('user')
  renderFull(bubble.body, payload.body, /* runKaTeX */ true)
  if (payload.attachments.length > 0) {
    const list = document.createElement('div')
    list.className = 'chat-attachments'
    for (const attachment of payload.attachments) {
      list.appendChild(makeAttachment(attachment))
    }
    bubble.body.appendChild(list)
  }
  return bubble
}

const MAX_PAPER_CARDS = 10

function normalizePaperGroup(value) {
  if (!value || typeof value !== 'object' || !Array.isArray(value.items)) return []
  const seen = new Set()
  const papers = []
  for (const raw of value.items.slice(0, MAX_PAPER_CARDS)) {
    if (!raw || typeof raw !== 'object') continue
    if (typeof raw.title !== 'string' || typeof raw.badge !== 'string') continue
    const title = raw.title.trim()
    const badge = raw.badge.trim()
    if (!title || title.length > 500 || !badge || badge.length > 64) continue
    const authors = typeof raw.authors === 'string' ? raw.authors.trim() : null
    if (authors != null && (!authors || authors.length > 1000)) continue
    const year = Number.isInteger(raw.year) && raw.year >= 1 && raw.year <= 9999
      ? raw.year
      : null

    if (raw.kind === 'library') {
      const referenceId = raw.referenceId
      if (!Number.isSafeInteger(referenceId) || referenceId <= 0) continue
      const key = `library:${referenceId}`
      if (seen.has(key)) continue
      seen.add(key)
      papers.push({ kind: 'library', referenceId, title, authors, year, badge })
      continue
    }

    if (raw.kind === 'web' && typeof raw.url === 'string' && raw.url.length <= 2048) {
      let url
      try {
        const parsed = new URL(raw.url)
        if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') continue
        if (!parsed.hostname) continue
        url = parsed.href
      } catch (_) {
        continue
      }
      const key = `web:${url}`
      if (seen.has(key)) continue
      seen.add(key)
      papers.push({ kind: 'web', url, title, authors, year, badge })
    }
  }
  return papers
}

function paperText(className, text) {
  const span = document.createElement('span')
  span.className = className
  span.textContent = text
  return span
}

function briefPaperAuthors(full) {
  if (!full) return '—'
  const authors = full.split(',').map((author) => author.trim()).filter(Boolean)
  return authors.length > 2 ? `${authors.slice(0, 2).join(', ')}, et al.` : full
}

function makePaperCard(paper) {
  const root = document.createElement(paper.kind === 'library' ? 'button' : 'div')
  root.className = `chat-paper-card chat-paper-${paper.kind}`
  root.title = paper.title

  if (paper.kind === 'library') {
    root.type = 'button'
    root.dataset.referenceId = String(paper.referenceId)
    root.setAttribute('aria-label', `Open ${paper.title}`)
  }

  root.appendChild(paperText('chat-paper-title', paper.title))
  const metadata = document.createElement('span')
  metadata.className = 'chat-paper-metadata'
  const authors = paperText('chat-paper-authors', briefPaperAuthors(paper.authors))
  if (paper.authors) authors.title = paper.authors
  metadata.appendChild(authors)
  const facts = document.createElement('span')
  facts.className = 'chat-paper-facts'
  facts.appendChild(paperText('chat-paper-year', paper.year == null ? '—' : String(paper.year)))
  facts.appendChild(paperText('chat-paper-separator', '·'))
  facts.appendChild(paperText('chat-paper-badge', paper.badge))
  metadata.appendChild(facts)
  root.appendChild(metadata)

  if (paper.kind === 'web') {
    const actions = document.createElement('span')
    actions.className = 'chat-paper-actions'
    const open = document.createElement('button')
    open.type = 'button'
    open.className = 'chat-paper-action chat-paper-open-source'
    open.dataset.url = paper.url
    open.textContent = 'Open source'
    const add = document.createElement('button')
    add.type = 'button'
    add.className = 'chat-paper-action chat-paper-add-source'
    add.dataset.url = paper.url
    add.textContent = 'Add to Rubien…'
    actions.appendChild(open)
    actions.appendChild(add)
    root.appendChild(actions)
  }
  return root
}

function makePaperGroup(value) {
  const papers = normalizePaperGroup(value)
  if (papers.length === 0) return null
  const root = document.createElement('section')
  root.className = 'chat-paper-group'
  root.setAttribute('aria-label', 'Document cards')
  const heading = document.createElement('div')
  heading.className = 'chat-paper-heading'
  heading.textContent = 'Document cards'
  root.appendChild(heading)
  const list = document.createElement('div')
  list.className = 'chat-paper-list'
  for (const paper of papers) list.appendChild(makePaperCard(paper))
  root.appendChild(list)
  return root
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
  if (role === 'paper') {
    let group
    try {
      group = JSON.parse(m?.body ?? '{}')
    } catch (_) {
      return
    }
    const row = makePaperGroup(group)
    if (row) transcript.appendChild(row)
    return
  }
  if (role === 'tool') {
    let chip
    try {
      chip = JSON.parse(m?.body ?? '{}')
    } catch (_) {
      chip = { name: 'tool', detail: String(m?.body ?? ''), status: 'started' }
    }
    appendToolChip(chip)
    return
  }
  if (role === 'notice') {
    const n = makeNotice()
    n.body.innerHTML = renderMarkdown(m?.body ?? '')
    transcript.appendChild(n.root)
    return
  }
  // user | assistant (default)
  const bubble = role === 'user'
    ? renderUserPayload({ body: m?.body ?? '', attachments: m?.attachments })
    : makeBubble('assistant')
  if (role !== 'user') renderFull(bubble.body, m?.body ?? '', /* runKaTeX */ true)
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

  addUserMessage(payload) {
    const bubble = renderUserPayload(payload)
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
    appendToolChip(chip || {})
    followOrHint(true)
  },

  addPaperGroup(group) {
    const row = makePaperGroup(group)
    if (!row) return
    transcript.appendChild(row)
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
    const libraryPaper = e.target.closest('.chat-paper-library')
    if (libraryPaper) {
      e.preventDefault()
      const referenceId = Number(libraryPaper.dataset.referenceId)
      if (Number.isSafeInteger(referenceId) && referenceId > 0) {
        post('openPaperReference', { referenceId })
      }
      return
    }
    const openSource = e.target.closest('.chat-paper-open-source')
    if (openSource) {
      e.preventDefault()
      post('openPaperSource', { url: openSource.dataset.url || '' })
      return
    }
    const addSource = e.target.closest('.chat-paper-add-source')
    if (addSource) {
      e.preventDefault()
      post('addPaperSource', { url: addSource.dataset.url || '' })
      return
    }
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
