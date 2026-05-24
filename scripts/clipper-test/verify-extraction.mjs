// End-to-end smoke test of the bundled ClipperDefuddle.js against a live
// page in headless WebKit. Mirrors what Rubien's WKWebView does at clip
// time: load URL, wait for React hydration, inject the bundle, invoke
// RubienDefuddleExtract(), capture the result via mocked message
// handlers, and assert structural properties on result.content.
//
// Usage:
//   npm run verify-extraction -- https://yumoxu.notion.site/async-grpo-in-the-wild

import { webkit } from 'playwright';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const bundlePath = resolve(here, '../../Sources/Rubien/Resources/ClipperDefuddle.js');
const bundleJS = readFileSync(bundlePath, 'utf8');

const URL = process.argv[2] || 'https://yumoxu.notion.site/async-grpo-in-the-wild';

const browser = await webkit.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await context.newPage();

// Install message-handler mocks BEFORE any page script runs so the
// bundle's `window.webkit.messageHandlers.readerResult` access succeeds.
await page.addInitScript(() => {
  window.__lastReaderResult = null;
  window.__debugMessages = [];
  window.webkit = {
    messageHandlers: {
      readerResult: { postMessage: (p) => { window.__lastReaderResult = p; } },
      RubienClipperDebug: { postMessage: (m) => { window.__debugMessages.push(m); } },
    },
  };
});

// Long Notion pages never settle to networkidle (ongoing analytics).
// Use domcontentloaded + an explicit poll for hydration below.
await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 90_000 });

// On Notion hosts, wait for React hydration ([data-block-id] elements).
// Non-Notion sites use Defuddle's normal path with no hydration poll.
const isNotionURL = /(?:^|\.)(notion\.site|notion\.so)$/.test(new globalThis.URL(URL).hostname);
if (isNotionURL) {
  // Phase 1: wait for the first block to appear.
  let blockCount = 0;
  for (let i = 0; i < 30; i++) {
    blockCount = await page.evaluate(() => document.querySelectorAll('[data-block-id]').length);
    if (blockCount > 0) break;
    await new Promise((r) => setTimeout(r, 1_000));
  }
  if (blockCount === 0) {
    console.error('FAIL: Notion did not hydrate within 30s. Page served the marketing fallback.');
    await browser.close();
    process.exit(1);
  }
  // Phase 2: wait until the block count stabilizes for 2 consecutive seconds.
  // Code blocks and inline math are often lazy-rendered AFTER the first
  // text blocks appear; extracting too early misses them.
  let prev = blockCount;
  let stable = 0;
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 1_000));
    const now = await page.evaluate(() => document.querySelectorAll('[data-block-id]').length);
    if (now === prev) {
      stable++;
      if (stable >= 2) break;
    } else {
      stable = 0;
      prev = now;
    }
  }
}

// Inject the bundle.
await page.evaluate(bundleJS);

// Invoke the extractor and wait for the async result to land via
// postMessage.
await page.evaluate(() => RubienDefuddleExtract());
let result = null;
// Poll up to 15s — covers Swift's 8s safety-net plus extraction worst case
// (~5s pre-expansion + ~1-2s Defuddle parseAsync on math/toggle-heavy pages).
for (let i = 0; i < 75; i++) {
  result = await page.evaluate(() => window.__lastReaderResult);
  if (result) break;
  await new Promise((r) => setTimeout(r, 200));
}

const debugMessages = await page.evaluate(() => window.__debugMessages);

// Did the normalizer's mutations persist in the live DOM?
const liveDomState = await page.evaluate(() => ({
  preCount: document.querySelectorAll('pre').length,
  codeCount: document.querySelectorAll('code').length,
  notionWrapperRemaining: document.querySelectorAll('div.notion-code-block[data-block-id]').length,
}));

await browser.close();

if (!result) {
  console.error('FAIL: RubienDefuddleExtract did not deliver a result within 15s.');
  console.error('Debug messages:', debugMessages);
  process.exit(1);
}

// Structural assertions.
const content = result.content || '';
const checks = {
  ok: result.ok === true,
  source_defuddle: result.source === 'defuddle',
  has_pre_tag: /<pre\b/.test(content),
  has_code_tag: /<code\b/.test(content),
  has_math: /<math\b/.test(content),
  has_ul: /<ul\b/.test(content),
  has_li: /<li\b/.test(content),
  title_present: !!result.title,
  title_not_notion_literal: result.title !== 'Notion',
  contentLength: content.length,
  preCount: (content.match(/<pre\b/g) || []).length,
  codeCount: (content.match(/<code\b/g) || []).length,
  mathCount: (content.match(/<math\b/g) || []).length,
  ulCount: (content.match(/<ul\b/g) || []).length,
  olCount: (content.match(/<ol\b/g) || []).length,
  liCount: (content.match(/<li\b/g) || []).length,
  h2Count: (content.match(/<h2\b/g) || []).length,
  h3Count: (content.match(/<h3\b/g) || []).length,
  h4Count: (content.match(/<h4\b/g) || []).length,
  imgCount: (content.match(/<img\b/g) || []).length,
  figureCount: (content.match(/<figure\b/g) || []).length,
  tableCount: (content.match(/<table\b/g) || []).length,
  hrCount: (content.match(/<hr\b/g) || []).length,
  detailsCount: (content.match(/<details\b/g) || []).length,
  asideCount: (content.match(/<aside\b/g) || []).length,
  blockquoteCount: (content.match(/<blockquote\b/g) || []).length,
  embedPlaceholderCount: (content.match(/rubien-notion-embed/g) || []).length,
  unknownBlockCount: (content.match(/rubien-notion-unknown/g) || []).length,
  notionExtractedDebugPresent: debugMessages.some((m) => m.phase === 'rubien_defuddle_notion_extracted'),
  togglesExpandedDebugPresent: debugMessages.some((m) => m.phase === 'rubien_defuddle_notion_toggles_expanded'),
};

console.log(JSON.stringify({
  url: URL,
  title: result.title,
  checks,
  debugPhases: debugMessages.map((m) => m.phase),
  debugDetails: debugMessages.filter((m) => m.detail).map((m) => `${m.phase}: ${m.detail}`),
  liveDomState,
  contentSampleAroundFirstPre: (() => {
    const idx = content.indexOf('<pre');
    if (idx < 0) return null;
    return content.slice(Math.max(0, idx - 80), idx + 600);
  })(),
  contentSampleAroundCodeText: (() => {
    // Known-good code-text strings from the diagnostic output for this URL.
    for (const needle of ['rollout_workers', '@misc{xu2026async']) {
      const idx = content.indexOf(needle);
      if (idx >= 0) {
        return {
          needle,
          foundAt: idx,
          sample: content.slice(Math.max(0, idx - 200), idx + 400),
        };
      }
    }
    return { needle: 'none found' };
  })(),
}, null, 2));

const isNotionHost = /(?:^|\.)(notion\.site|notion\.so)$/.test(new globalThis.URL(URL).hostname);
// Universal checks (every successful extraction must satisfy these).
// Content-shape checks (pre/code/math/li) are NOT in the pass gate
// because they're page-dependent — a doc with no code blocks legitimately
// has zero <pre> tags. They're emitted in the JSON output for inspection.
const passed =
  checks.ok &&
  checks.source_defuddle &&
  checks.title_present &&
  checks.title_not_notion_literal &&
  checks.contentLength > 1000 &&
  checks.unknownBlockCount === 0 &&
  (!isNotionHost || checks.notionExtractedDebugPresent);
if (!passed) {
  console.error('FAIL: structural checks did not all pass.');
  process.exit(1);
}
console.log('PASS: all structural checks passed.');
