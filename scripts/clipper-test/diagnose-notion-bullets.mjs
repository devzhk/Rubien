// Probe Notion's bullet-list DOM shape. Mirrors diagnose-notion.mjs
// but targets bullet/ordered list containers instead of code blocks.

import { webkit } from 'playwright';

const URL = process.argv[2] || 'https://yumoxu.notion.site/async-grpo-in-the-wild';

const browser = await webkit.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await context.newPage();

await page.goto(URL, { waitUntil: 'networkidle', timeout: 60_000 });

let blockCount = 0;
for (let i = 0; i < 30; i++) {
  blockCount = await page.evaluate(() => document.querySelectorAll('[data-block-id]').length);
  if (blockCount > 0) break;
  await new Promise((r) => setTimeout(r, 1_000));
}
if (blockCount === 0) {
  console.error('Notion did not hydrate.');
  await browser.close();
  process.exit(1);
}

const result = await page.evaluate(() => {
  const candidates = [
    'ul', 'ol', 'li',
    '[class*="bulleted-list"]', '[class*="numbered-list"]',
    '[class*="bullet"]', '[class*="list-item"]',
    'div[data-block-id][class*="list"]',
    'div[data-block-id][class*="ulist"]',
    'div[data-block-id][class*="olist"]',
  ];
  const seen = new Set();
  const findings = [];
  for (const sel of candidates) {
    let nodes;
    try { nodes = document.querySelectorAll(sel); } catch (_) { continue; }
    for (const node of Array.from(nodes).slice(0, 4)) {
      if (seen.has(node)) continue;
      seen.add(node);
      findings.push({
        matchedBy: sel,
        outerTag: node.tagName,
        outerClass: node.className,
        outerDataAttrs: Array.from(node.attributes)
          .filter((a) => a.name.startsWith('data-'))
          .map((a) => `${a.name}="${a.value.slice(0, 60)}"`),
        textSample: (node.textContent || '').slice(0, 150),
        outerHTMLSample: node.outerHTML.slice(0, 1200),
      });
    }
  }
  return {
    selectorCounts: candidates.reduce((acc, sel) => {
      try { acc[sel] = document.querySelectorAll(sel).length; } catch (_) { acc[sel] = 'err'; }
      return acc;
    }, {}),
    sampleBlocks: findings.slice(0, 6),
  };
});

console.log(JSON.stringify(result, null, 2));
await browser.close();
