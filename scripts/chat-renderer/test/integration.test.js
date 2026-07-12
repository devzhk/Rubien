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
  const posts = { openExternalLink: [], copyCode: [] }
  window.webkit = {
    messageHandlers: {
      chatReady: { postMessage: () => {} },
      openExternalLink: { postMessage: (m) => posts.openExternalLink.push(m) },
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
    'appendDelta', 'commitAssistantMessage', 'addToolChip', 'addNotice', 'setTheme']) {
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
  assert.equal(T().querySelectorAll('.chat-msg, .chat-notice, .chat-tool-chip').length, 0, 'reset cleared transcript')
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
