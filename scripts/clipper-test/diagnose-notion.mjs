// Drives Playwright's WebKit browser headlessly against a Notion page,
// waits for React hydration, and dumps the live DOM shape of any
// code-block-like containers. Used to derive the selectors the Notion
// code-block normalizer in scripts/clipper/src/clipper-defuddle.js needs.
//
// Usage:
//   npm run diagnose-notion -- https://yumoxu.notion.site/async-grpo-in-the-wild
//
// Why WebKit (not Chromium): Notion serves a marketing-fallback shell
// to non-WebKit headless browsers regardless of UA/anti-detection
// shimming. Real WebKit (Safari engine, what Rubien's WKWebView uses)
// gets the real React-rendered content. Playwright bundles its own
// WebKit binary so this works identically on macOS and Linux.

import { webkit } from 'playwright';

const URL = process.argv[2] || 'https://yumoxu.notion.site/async-grpo-in-the-wild';

const browser = await webkit.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
});
const page = await context.newPage();

await page.goto(URL, { waitUntil: 'networkidle', timeout: 60_000 });

// Poll up to 30 s for actual content to land. networkidle isn't
// sufficient — Notion's React app populates the DOM after the page
// reports idle.
let bodyLen = 0;
let blockCount = 0;
for (let i = 0; i < 30; i++) {
  bodyLen = await page.evaluate(() => (document.body ? document.body.innerHTML.length : 0));
  blockCount = await page.evaluate(() => document.querySelectorAll('[data-block-id]').length);
  if (bodyLen > 50_000 && blockCount > 0) break;
  await new Promise((r) => setTimeout(r, 1_000));
}

const hydrationStatus = { bodyLen, blockCount };

if (blockCount === 0) {
  const fallback = await page.evaluate(() => ({
    title: document.title,
    textSample: (document.body ? document.body.innerText : '').slice(0, 200),
  }));
  console.log(JSON.stringify({ hydrationStatus, hydrationFailed: true, fallback }, null, 2));
  await browser.close();
  process.exit(1);
}

const result = await page.evaluate(() => {
  const candidates = [
    'pre',
    'div[data-block-id]:has(pre)',
    'div[data-block-id]:has(code)',
    '[class*="code-block"]',
    '[class*="notion-code"]',
    '[data-content-type="code"]',
  ];
  const seen = new Set();
  const findings = [];
  for (const sel of candidates) {
    let nodes;
    try { nodes = document.querySelectorAll(sel); } catch (_) { continue; }
    for (const node of nodes) {
      let outer = node;
      while (
        outer.parentElement &&
        outer.parentElement.matches('[data-block-id], [class*="code"], pre, code') &&
        !seen.has(outer.parentElement)
      ) {
        outer = outer.parentElement;
      }
      if (seen.has(outer)) continue;
      seen.add(outer);
      const pre = outer.querySelector('pre');
      const code = outer.querySelector('code');
      findings.push({
        matchedBy: sel,
        outerTag: outer.tagName,
        outerClass: outer.className,
        outerDataAttrs: Array.from(outer.attributes)
          .filter((a) => a.name.startsWith('data-'))
          .map((a) => `${a.name}="${a.value.slice(0, 60)}"`),
        hasPre: !!pre,
        hasCode: !!code,
        langCandidates: {
          outerDataLanguage: outer.getAttribute('data-language'),
          codeDataLanguage: code && code.getAttribute('data-language'),
          codeClass: code && code.className,
          preClass: pre && pre.className,
        },
        textSample: (outer.textContent || '').slice(0, 200),
        outerHTMLSample: outer.outerHTML.slice(0, 1500),
      });
    }
  }
  return { url: location.href, total: findings.length, blocks: findings.slice(0, 3) };
});

console.log(JSON.stringify({ hydrationStatus, ...result }, null, 2));
await browser.close();
