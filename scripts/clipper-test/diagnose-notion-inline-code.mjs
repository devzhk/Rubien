// Probe Notion's inline-code DOM shape. Notion's "inline code"
// (Cmd+E formatting on selected text within a paragraph) renders as
// a span with monospace styling, distinct from a code block (which is
// a standalone div.notion-code-block we already handle).

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
  // Look for spans that have monospace font, distinguishing them from
  // regular text spans. Notion inline-code styling includes a monospace
  // font-family in the inline style.
  const candidates = [
    'span[class*="notion-inline-code"]',
    'code',
    // Cast a wider net for spans with monospace styling
    'span[style*="monospace"]',
    'span[style*="SFMono"]',
    'span[style*="Menlo"]',
    'span[style*="Courier"]',
  ];
  const seen = new Set();
  const findings = [];
  for (const sel of candidates) {
    let nodes;
    try { nodes = document.querySelectorAll(sel); } catch (_) { continue; }
    for (const node of Array.from(nodes).slice(0, 5)) {
      // Skip if it's inside a code block (we already handle those).
      if (node.closest('.notion-code-block')) continue;
      if (seen.has(node)) continue;
      seen.add(node);
      findings.push({
        matchedBy: sel,
        outerTag: node.tagName,
        outerClass: node.className,
        outerStyle: (node.getAttribute('style') || '').slice(0, 200),
        outerDataAttrs: Array.from(node.attributes)
          .filter((a) => a.name.startsWith('data-'))
          .map((a) => `${a.name}="${a.value.slice(0, 60)}"`),
        textSample: (node.textContent || '').slice(0, 120),
        outerHTMLSample: node.outerHTML.slice(0, 600),
        parentTag: node.parentElement && node.parentElement.tagName,
        parentClass: node.parentElement && node.parentElement.className,
      });
    }
  }
  return {
    selectorCounts: candidates.reduce((acc, sel) => {
      try { acc[sel] = document.querySelectorAll(sel).length; } catch (_) { acc[sel] = 'err'; }
      return acc;
    }, {}),
    sampleSpans: findings.slice(0, 6),
  };
});

console.log(JSON.stringify(result, null, 2));
await browser.close();
