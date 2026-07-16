// integration.test.js — `node --test` + jsdom. Drives the COMMITTED build
// artifact (`Sources/Rubien/Resources/ChatTranscript.html`) end-to-end through
// the real `window.RubienChat` API — the same DOM the WKWebView paints — so the
// renderer's behavioral + security guarantees are permanently regression-tested,
// not just spot-checked at build time.
//
// This validates the artifact that ships. If you change `src/` you MUST rerun
// `npm run build` (regenerating ChatTranscript.html) before this test reflects it.
//
// KaTeX/marked/DOMPurify all run here (inline in the built HTML), so this covers
// what src/render.js unit tests cannot: KaTeX-on-commit timing and the KaTeX
// `trust:false` boundary for hostile math.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'
import { JSDOM } from 'jsdom'

const __dirname = dirname(fileURLToPath(import.meta.url))
const htmlPath = resolve(__dirname, '../../../Sources/Rubien/Resources/ChatTranscript.html')

// Build a fresh jsdom document with the bundle executed and the Swift bridge
// (window.webkit.messageHandlers) shimmed to capture JS→Swift posts.
async function boot() {
  const html = readFileSync(htmlPath, 'utf-8')
  const dom = new JSDOM(html, { runScripts: 'dangerously', pretendToBeVisual: true })
  const { window } = dom
  const posts = {
    openExternalLink: [],
    openPaperReference: [],
    openPaperSource: [],
    addPaperSource: [],
    copyCode: [],
  }
  window.webkit = {
    messageHandlers: {
      chatReady: { postMessage: () => {} },
      openExternalLink: { postMessage: (m) => posts.openExternalLink.push(m) },
      openPaperReference: { postMessage: (m) => posts.openPaperReference.push(m) },
      openPaperSource: { postMessage: (m) => posts.openPaperSource.push(m) },
      addPaperSource: { postMessage: (m) => posts.addPaperSource.push(m) },
      copyCode: { postMessage: (m) => posts.copyCode.push(m) },
    },
  }
  await new Promise((r) => setTimeout(r, 60)) // let inline scripts + init settle
  const doc = window.document
  return { window, doc, posts, R: window.RubienChat, T: () => doc.getElementById('transcript') }
}

const tick = (ms = 80) => new Promise((r) => setTimeout(r, ms))

test('window.RubienChat exposes the full contract', async () => {
  const { R } = await boot()
  assert.ok(R && typeof R === 'object', 'window.RubienChat installed')
  for (const m of ['reset', 'loadTranscript', 'addUserMessage', 'beginAssistantMessage',
    'appendDelta', 'commitAssistantMessage', 'addToolChip', 'addPaperGroup',
    'addNotice', 'setTheme']) {
    assert.equal(typeof R[m], 'function', `RubienChat.${m} is a function`)
  }
})

test('user message renders markdown + KaTeX immediately', async () => {
  const { R, T } = await boot()
  R.addUserMessage('# H\n\nInline $E=mc^2$ and $$\\int_0^1 x^2\\,dx = \\tfrac13$$\n\n- a\n- b\n\n**bold**')
  await tick()
  const u = T().querySelector('.chat-msg-user .chat-bubble')
  assert.ok(u, 'user bubble created')
  assert.ok(u.querySelector('h1'), 'heading rendered')
  assert.ok(u.querySelectorAll('li').length >= 2, 'list rendered')
  assert.ok(u.querySelector('strong'), 'bold rendered')
  assert.ok(u.querySelectorAll('.katex').length >= 2, 'both formulas typeset')
})

test('user attachment payload renders safe chips and unavailable state', async () => {
  const { R, T } = await boot()
  R.addUserMessage({ body: '', attachments: [
    { id: '1', displayName: '<img onerror=alert(1)>.md', kind: 'text', byteCount: 42, isAvailable: true,
      path: '/Users/researcher/private-notes.md' },
    { id: '2', displayName: 'gone.png', kind: 'image', byteCount: 99, isAvailable: false },
  ] })
  await tick()
  const bubble = T().querySelector('.chat-msg-user .chat-bubble')
  assert.equal(bubble.querySelectorAll('.chat-attachment').length, 2)
  assert.match(bubble.textContent, /<img onerror=alert\(1\)>\.md/)
  assert.match(bubble.textContent, /File unavailable/)
  assert.equal(bubble.querySelectorAll('[onerror]').length, 0)
  assert.doesNotMatch(bubble.textContent, /private-notes|\/Users\//)
})

test('user attachment rendering is identical after restore and only allows png/jpeg thumbnails', async () => {
  const payload = {
    body: 'See **these**',
    attachments: [
      { id: '1', displayName: 'ok.png', kind: 'image', byteCount: 12, isAvailable: true,
        thumbnailDataURL: 'data:image/png;base64,AA==' },
      { id: '2', displayName: 'bad.svg', kind: 'image', byteCount: 34, isAvailable: true,
        thumbnailDataURL: 'data:image/svg+xml;base64,PHN2Zz4=' },
      { id: '3', displayName: 'ok.jpeg', kind: 'image', byteCount: 56, isAvailable: true,
        thumbnailDataURL: 'data:image/jpeg;base64,AA==' },
    ],
  }

  const live = await boot()
  live.R.addUserMessage(payload)
  await tick()
  const liveBubble = live.T().querySelector('.chat-msg-user .chat-bubble')
  assert.equal(liveBubble.querySelectorAll('.chat-attachment-thumbnail').length, 2)
  assert.equal(liveBubble.querySelector('.chat-attachment-thumbnail').getAttribute('src'),
    'data:image/png;base64,AA==')

  const restored = await boot()
  restored.R.loadTranscript([{ role: 'user', body: payload.body, attachments: payload.attachments, seq: 0 }])
  await tick()
  const restoredBubble = restored.T().querySelector('.chat-msg-user .chat-bubble')
  assert.equal(restoredBubble.innerHTML, liveBubble.innerHTML)
  assert.doesNotMatch(restoredBubble.innerHTML, /svg\+xml|PHN2Zz4=/)
})

test('KaTeX runs on commit, never during streaming', async () => {
  const { R, T } = await boot()
  R.beginAssistantMessage()
  const full = 'The integral $$\\int_0^1 x^2\\,dx = \\tfrac13$$ is complete.'
  for (let i = 0; i < full.length; i += 5) R.appendDelta(full.slice(i, i + 5))
  await tick(120)
  const streaming = [...T().querySelectorAll('.chat-msg-assistant .chat-bubble')].pop()
  assert.equal(streaming.querySelectorAll('.katex').length, 0, 'no KaTeX mid-stream')
  R.commitAssistantMessage(full)
  await tick()
  const committed = [...T().querySelectorAll('.chat-msg-assistant .chat-bubble')].pop()
  assert.ok(committed.querySelectorAll('.katex').length >= 1, 'KaTeX after commit')
})

test('tool chips + notices render with status variants', async () => {
  const { R, T } = await boot()
  R.addToolChip({ name: 'rubien_read_text', detail: 'pages 1-3', status: 'started' })
  R.addToolChip({ name: 'rubien_get', detail: null, status: 'completed' })
  R.addToolChip({ name: 'Write', detail: 'notes.md', status: 'denied' })
  R.addNotice('Rate limit reached.')
  await tick()
  assert.equal(T().querySelectorAll('.chat-tool-chip').length, 3)
  assert.ok(T().querySelector('.chat-tool-started'))
  assert.ok(T().querySelector('.chat-tool-completed'))
  assert.ok(T().querySelector('.chat-tool-denied'))
  assert.ok(T().querySelector('.chat-notice'))
  assert.match(T().querySelector('.chat-tool-name').textContent, /rubien_read_text/)
})

test('paper groups are chronological, bounded, inert, and expose explicit native actions', async () => {
  const { window, R, T, posts } = await boot()
  R.addUserMessage('Recommend papers')
  R.addPaperGroup({ items: [
    {
      kind: 'library', referenceId: 7,
      title: '<img src=x onerror=alert(1)> A very long library title',
      authors: 'Yiyou Sun, Xinyang Han, Weichen Zhang',
      badge: 'PDF',
    },
    {
      kind: 'web', url: 'https://example.com/paper', title: 'Web paper',
      year: 2025, badge: 'Web candidate',
    },
    ...Array.from({ length: 12 }, (_, i) => ({
      kind: 'library', referenceId: 100 + i, title: `Extra ${i}`, year: 2020, badge: 'Library',
    })),
  ] })
  R.addNotice('Later transcript content')
  await tick()

  const group = T().querySelector('.chat-paper-group')
  assert.ok(group)
  assert.equal(group.getAttribute('aria-label'), 'Paper cards')
  assert.equal(group.querySelector('.chat-paper-heading').textContent, 'Paper cards')
  assert.equal(group.querySelectorAll('.chat-paper-card').length, 10, 'the bridge caps a group at ten')
  const library = group.querySelector('.chat-paper-library')
  assert.equal(library.title, '<img src=x onerror=alert(1)> A very long library title')
  assert.equal(library.querySelector('.chat-paper-title').textContent,
    '<img src=x onerror=alert(1)> A very long library title')
  assert.equal(library.querySelectorAll('img').length, 0, 'title is inserted with textContent only')
  assert.equal(library.querySelector('.chat-paper-authors').textContent,
    'Yiyou Sun, Xinyang Han, et al.')
  assert.equal(library.querySelector('.chat-paper-authors').title,
    'Yiyou Sun, Xinyang Han, Weichen Zhang')
  assert.equal(library.querySelector('.chat-paper-year').textContent, '—')
  assert.equal(library.querySelector('.chat-paper-badge').textContent, 'PDF')
  assert.equal(posts.addPaperSource.length, 0, 'rendering never auto-imports a web result')

  library.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }))
  assert.equal(posts.openPaperReference.at(-1)?.referenceId, 7)
  assert.equal(typeof posts.openPaperReference.at(-1)?.referenceId, 'number')

  group.querySelector('.chat-paper-open-source')
    .dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }))
  assert.equal(posts.openPaperSource.at(-1)?.url, 'https://example.com/paper')
  group.querySelector('.chat-paper-add-source')
    .dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }))
  assert.equal(posts.addPaperSource.at(-1)?.url, 'https://example.com/paper')

  const children = [...T().children]
  assert.ok(children.indexOf(group) > children.findIndex((row) => row.classList.contains('chat-msg-user')))
  assert.ok(children.indexOf(group) < children.findIndex((row) => row.classList.contains('chat-notice')),
    'later transcript rows do not replace or move the paper group')
})

test('paper groups restore in seq order and survive later turns', async () => {
  const { R, T } = await boot()
  const paperBody = JSON.stringify({ items: [
    { kind: 'library', referenceId: 9, title: 'Persistent paper', year: 2024, badge: 'PDF' },
  ] })
  R.loadTranscript([
    { role: 'assistant', body: 'First answer', seq: 0 },
    { role: 'paper', body: paperBody, seq: 1 },
    { role: 'user', body: 'A later turn', seq: 2 },
    { role: 'assistant', body: 'Later answer', seq: 3 },
  ])
  await tick()
  const children = [...T().children]
  assert.deepEqual(children.map((node) => node.classList.contains('chat-paper-group')
    ? 'paper'
    : node.classList.contains('chat-msg-user') ? 'user' : 'assistant'),
  ['assistant', 'paper', 'user', 'assistant'])
  assert.equal(T().querySelectorAll('.chat-paper-group').length, 1)
  assert.match(T().textContent, /Persistent paper/)
})

test('consecutive tool calls fold after two and keep the latest call visible', async () => {
  const { window, doc, R, T } = await boot()
  R.addToolChip({ name: 'first', status: 'completed' })
  R.addToolChip({ name: 'second', status: 'completed' })
  assert.equal(T().querySelector('.chat-tool-group'), null, 'two calls stay fully visible')

  R.addToolChip({ name: 'third', status: 'completed' })
  await tick()
  const group = T().querySelector('.chat-tool-group')
  const history = group.querySelector('.chat-tool-history')
  const latest = group.querySelector('.chat-tool-latest')
  const toggle = group.querySelector('.chat-tool-toggle')
  assert.ok(history.hidden, 'earlier calls start folded')
  assert.equal(history.querySelectorAll('.chat-tool-chip').length, 2)
  assert.equal(latest.querySelector('.chat-tool-name').textContent, 'third')
  assert.equal(toggle.textContent.trim(), '+ 2 more tool calls')
  assert.equal(toggle.getAttribute('aria-expanded'), 'false')

  toggle.dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }))
  assert.equal(history.hidden, false, 'the disclosure reveals all earlier calls')
  assert.equal(toggle.getAttribute('aria-expanded'), 'true')
  assert.equal(toggle.textContent.trim(), 'Show fewer tool calls')

  R.addToolChip({ name: 'fourth', status: 'completed' })
  assert.equal(history.hidden, false, 'live additions preserve the expanded choice')
  assert.equal(history.querySelectorAll('.chat-tool-chip').length, 3)
  assert.equal(group.querySelector('.chat-tool-latest .chat-tool-name').textContent, 'fourth')

  toggle.dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }))
  assert.ok(history.hidden)
  assert.equal(toggle.textContent.trim(), '+ 3 more tool calls')

  R.addToolChip({ name: 'fifth', status: 'completed' })
  assert.ok(history.hidden, 'live additions also preserve the collapsed choice')
  assert.equal(history.querySelectorAll('.chat-tool-chip').length, 4)
  assert.equal(group.querySelector('.chat-tool-latest .chat-tool-name').textContent, 'fifth')

  toggle.focus()
  toggle.dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 0 }))
  assert.equal(doc.activeElement, history.querySelector('.chat-tool-chip summary'),
    'keyboard expansion enters the revealed calls in forward-navigation order')
})

test('an inspected tool remains visible when a third live call creates the group', async () => {
  const opened = await boot()
  opened.R.addToolChip({ name: 'open', detail: 'being read', status: 'completed' })
  opened.R.addToolChip({ name: 'second', status: 'completed' })
  opened.T().querySelector('.chat-tool-chip').open = true
  opened.R.addToolChip({ name: 'third', status: 'completed' })
  assert.equal(opened.T().querySelector('.chat-tool-history').hidden, false,
    'an open tool detail keeps the new group expanded')

  const focused = await boot()
  focused.R.addToolChip({ name: 'focused', status: 'completed' })
  focused.R.addToolChip({ name: 'second', status: 'completed' })
  const summary = focused.T().querySelector('.chat-tool-chip summary')
  summary.focus()
  assert.equal(focused.doc.activeElement, summary)
  focused.R.addToolChip({ name: 'third', status: 'completed' })
  assert.equal(focused.T().querySelector('.chat-tool-history').hidden, false,
    'a focused tool keeps the new group expanded')
  assert.equal(focused.doc.activeElement, summary, 'reparenting preserves keyboard focus')

  const advancing = await boot()
  advancing.R.addToolChip({ name: 'one', status: 'completed' })
  advancing.R.addToolChip({ name: 'two', status: 'completed' })
  advancing.R.addToolChip({ name: 'inspected latest', detail: 'being read', status: 'completed' })
  const latest = advancing.T().querySelector('.chat-tool-latest')
  const latestSummary = latest.querySelector('summary')
  latest.open = true
  latestSummary.focus()
  advancing.R.addToolChip({ name: 'new latest', status: 'completed' })
  assert.equal(advancing.T().querySelector('.chat-tool-history').hidden, false,
    'advancing the latest call keeps its inspected predecessor visible')
  assert.ok(latest.open)
  assert.equal(advancing.doc.activeElement, latestSummary)
})

test('live and restored transcripts group the same consecutive tool runs', async () => {
  const tool = (name, seq) => ({
    role: 'tool',
    body: JSON.stringify({ name, status: 'completed' }),
    seq,
  })
  const messages = [
    tool('one', 0), tool('two', 1), tool('three', 2),
    { role: 'user', body: 'break', seq: 3 },
    tool('four', 4), tool('five', 5), tool('six', 6),
  ]

  const live = await boot()
  live.R.addToolChip({ name: 'one', status: 'completed' })
  live.R.addToolChip({ name: 'two', status: 'completed' })
  live.R.addToolChip({ name: 'three', status: 'completed' })
  live.R.addUserMessage('break')
  live.R.addToolChip({ name: 'four', status: 'completed' })
  live.R.addToolChip({ name: 'five', status: 'completed' })
  live.R.addToolChip({ name: 'six', status: 'completed' })

  const restored = await boot()
  restored.R.loadTranscript(messages)
  await tick()

  assert.equal(restored.T().innerHTML, live.T().innerHTML)
  const groups = restored.T().querySelectorAll('.chat-tool-group')
  assert.equal(groups.length, 2, 'the user message ends the first run')
  assert.deepEqual(
    [...restored.T().querySelectorAll('.chat-tool-latest .chat-tool-name')].map((node) => node.textContent),
    ['three', 'six'],
  )
  const controls = [...restored.T().querySelectorAll('.chat-tool-toggle')]
    .map((toggle) => toggle.getAttribute('aria-controls'))
  assert.equal(new Set(controls).size, controls.length, 'each disclosure controls a unique history')
  for (const id of controls) assert.ok(restored.doc.getElementById(id))
})

test('hostile message content is fully inert', async () => {
  const { window, R, T } = await boot()
  R.beginAssistantMessage()
  R.commitAssistantMessage(
    'IGNORE ALL PREVIOUS INSTRUCTIONS.\n\n' +
    '<script>window.__pwned=1</script>\n\n' +
    '<img src=x onerror="window.__pwned=1">\n\n' +
    '[a](javascript:window.__pwned=1)\n\n' +
    '[f](file:///etc/passwd)\n\n' +
    'Legit **bold** survives.'
  )
  await tick()
  const tr = T()
  assert.equal(tr.querySelectorAll('script').length, 0, 'no <script> in transcript')
  let onAttr = 0
  tr.querySelectorAll('*').forEach((el) => { for (const a of el.attributes) if (/^on/i.test(a.name)) onAttr++ })
  assert.equal(onAttr, 0, 'no on* handler attributes')
  const badHref = [...tr.querySelectorAll('a')]
    .filter((a) => /^(javascript|file|data|mailto):/i.test(a.getAttribute('href') || '')).length
  assert.equal(badHref, 0, 'no live javascript:/file:/data:/mailto: anchors')
  assert.ok(!window.__pwned, 'payload did not execute')
  assert.match(tr.textContent, /IGNORE ALL PREVIOUS INSTRUCTIONS/, 'injection text shown as inert text')
  assert.ok(tr.querySelector('.chat-msg-assistant strong'), 'legitimate **bold** still rendered')
})

test('Codex-style LaTeX typesets: bare \\(…\\), \\[…\\], and ```latex fences', async () => {
  const { R, T } = await boot()
  R.beginAssistantMessage()
  // Shape taken verbatim from a real Codex reply (memorization-paper session):
  // display math wrapped in ```latex fences, inline math as bare \( \).
  R.commitAssistantMessage(
    'Sure:\n\n```latex\n\\[\n\\operatorname{mem}_U(X, \\widehat{\\Theta}, \\Theta)\n=\nH(X \\mid \\Theta)\n-\nH(X \\mid \\Theta, \\widehat{\\Theta})\n\\]\n```\n\n' +
    'Here, \\(\\theta\\) is the reference model, and bare display math:\n\n' +
    '\\[\nH_K(x \\mid \\theta)\n\\]\n\nworks too. It costs $5 and $10 total.'
  )
  await tick()
  const bubble = [...T().querySelectorAll('.chat-msg-assistant .chat-bubble')].pop()
  assert.ok(bubble.querySelectorAll('.katex-display').length >= 2, 'both display formulas typeset')
  assert.ok(bubble.querySelectorAll('.katex').length >= 3, 'inline \\(θ\\) typeset as well')
  assert.equal(bubble.querySelector('pre'), null, 'no code box around the latex fence')
  assert.equal(bubble.querySelector('h1,h2'), null, 'no setext headings from = / - formula lines')
  assert.match(bubble.textContent, /\$5 and \$10/, 'currency stays prose')
})

test('hostile math (KaTeX trust:false) produces no live link', async () => {
  const { R, T } = await boot()
  R.beginAssistantMessage()
  // \href is a trust-gated command; with trust:false KaTeX must not emit a live
  // <a href="javascript:…"> from untrusted LaTeX source.
  R.commitAssistantMessage('Danger: $\\href{javascript:alert(1)}{click me}$ and $x^2$.')
  await tick()
  const bubble = [...T().querySelectorAll('.chat-msg-assistant .chat-bubble')].pop()
  const jsHrefs = [...bubble.querySelectorAll('a')]
    .filter((a) => /^javascript:/i.test(a.getAttribute('href') || '')).length
  assert.equal(jsHrefs, 0, 'no javascript: anchor from \\href under trust:false')
  assert.ok(bubble.querySelectorAll('.katex').length >= 1, 'the benign $x^2$ still typeset')
})

test('http link click routes to Swift; reset clears transcript', async () => {
  const { window, R, T, posts } = await boot()
  R.addUserMessage('See [Anthropic](https://www.anthropic.com).')
  await tick()
  const link = [...T().querySelectorAll('.chat-msg-user a')].find((a) => /anthropic/.test(a.getAttribute('href') || ''))
  assert.ok(link, 'http link rendered')
  link.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }))
  await tick()
  assert.equal(posts.openExternalLink.at(-1)?.url, 'https://www.anthropic.com', 'openExternalLink posted with url')

  R.reset()
  await tick()
  assert.equal(T().querySelectorAll('.chat-msg, .chat-notice, .chat-tool-chip, .chat-paper-group').length,
    0, 'reset cleared transcript')
})

// jsdom has no layout engine (scrollHeight/clientHeight/scrollTop are 0), so fake a
// scroller with real numbers; scrollTo* also fires the 'scroll' event the
// follow-state listens for. Covers the stick-to-bottom + "N new messages" pill.
function fakeScroller(window, T, scrollHeight, clientHeight) {
  let top = 0
  Object.defineProperty(T, 'scrollHeight', { configurable: true, get: () => scrollHeight })
  Object.defineProperty(T, 'clientHeight', { configurable: true, get: () => clientHeight })
  Object.defineProperty(T, 'scrollTop', { configurable: true, get: () => top, set: (v) => { top = v } })
  const fire = () => T.dispatchEvent(new window.Event('scroll'))
  return { toBottom() { top = scrollHeight; fire() }, up() { top = 0; fire() } }
}

// Give the disclosure a deterministic 200 px history block. Its toggle sits
// below that block, so a correct expand/collapse implementation compensates
// scrollTop by the same amount and leaves the toggle at a stable viewport Y.
function fakeToolDisclosureLayout(window, T, history, toggle) {
  let top = 0
  const height = () => history.hidden ? 1000 : 1200
  Object.defineProperty(T, 'scrollHeight', { configurable: true, get: height })
  Object.defineProperty(T, 'clientHeight', { configurable: true, get: () => 300 })
  Object.defineProperty(T, 'scrollTop', {
    configurable: true,
    get: () => top,
    set: (value) => { top = Math.max(0, Math.min(value, height() - 300)) },
  })
  toggle.getBoundingClientRect = () => ({ top: 800 + (history.hidden ? 0 : 200) - top })
  const fire = () => T.dispatchEvent(new window.Event('scroll'))
  return {
    scrollTop: () => top,
    toggleTop: () => toggle.getBoundingClientRect().top,
    toBottom() { top = height() - 300; fire() },
    up() { top = 0; fire() },
  }
}

test('tool disclosure preserves its scroll anchor and refreshes follow state', async () => {
  const { window, doc, R, T } = await boot()
  R.addToolChip({ name: 'one', status: 'completed' })
  R.addToolChip({ name: 'two', status: 'completed' })
  R.addToolChip({ name: 'three', status: 'completed' })
  const history = T().querySelector('.chat-tool-history')
  const toggle = T().querySelector('.chat-tool-toggle')
  const layout = fakeToolDisclosureLayout(window, T(), history, toggle)

  layout.toBottom()
  const bottomAnchor = layout.toggleTop()
  toggle.dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }))
  assert.equal(layout.toggleTop(), bottomAnchor, 'expanding keeps the disclosure anchored')
  assert.equal(layout.scrollTop(), 900, 'the bottom-following position grows with the history')
  toggle.dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }))
  assert.equal(layout.toggleTop(), bottomAnchor, 'collapsing keeps the disclosure anchored')
  assert.equal(layout.scrollTop(), 700)

  layout.up()
  const readingAnchor = layout.toggleTop()
  toggle.dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }))
  assert.equal(layout.toggleTop(), readingAnchor)
  assert.equal(layout.scrollTop(), 200)
  R.addToolChip({ name: 'four', status: 'completed' })
  assert.equal(layout.scrollTop(), 200, 'a later call does not snap a reader to the bottom')
  assert.equal(doc.getElementById('chat-jump').textContent, '1 new message')
  assert.ok(doc.getElementById('chat-jump').classList.contains('is-visible'))
})

test('stick-to-bottom: follows silently at bottom, pills when scrolled up', async () => {
  const { window, doc, R, T } = await boot()
  const pill = () => doc.getElementById('chat-jump')
  const s = fakeScroller(window, T(), 1000, 300)

  s.toBottom()
  R.addToolChip({ name: 'read', status: 'completed' })
  await tick()
  assert.equal(pill().classList.contains('is-visible'), false, 'no pill while following the bottom')

  s.up()
  R.addToolChip({ name: 'read', status: 'completed' })
  await tick()
  assert.ok(pill().classList.contains('is-visible'), 'pill appears once scrolled up')
  assert.equal(pill().textContent, '1 new message')
  R.addNotice('hi')
  await tick()
  assert.equal(pill().textContent, '2 new messages', 'each new item counts')

  pill().dispatchEvent(new window.MouseEvent('click', { bubbles: true }))
  await tick()
  assert.equal(pill().classList.contains('is-visible'), false, 'clicking the pill clears it')
})

test('stick-to-bottom: a reply scrolled away from mid-stream still pills exactly once', async () => {
  const { window, doc, R, T } = await boot()
  const pill = () => doc.getElementById('chat-jump')
  const s = fakeScroller(window, T(), 1000, 300)

  s.toBottom()
  R.beginAssistantMessage() // began while following → no pill
  R.appendDelta('Thinking…')
  await tick()
  assert.equal(pill().classList.contains('is-visible'), false)

  s.up() // user scrolls up mid-reply
  R.appendDelta(' more')
  await tick()
  assert.ok(pill().classList.contains('is-visible'), 'a streamed reply surfaces the pill')
  assert.equal(pill().textContent, '1 new message')
  R.appendDelta(' and more')
  await tick()
  assert.equal(pill().textContent, '1 new message', 'streaming growth is not re-counted per delta')
})
