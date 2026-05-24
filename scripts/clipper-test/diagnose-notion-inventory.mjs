// Complete inventory of Notion's [data-block-id] class patterns on a
// given page. Feeds the unified-extractor plan: we need to know every
// block type the extractor must dispatch on.

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
if (blockCount === 0) { await browser.close(); process.exit(1); }

const result = await page.evaluate(() => {
  // Tally distinct class patterns on [data-block-id] elements
  const blocks = document.querySelectorAll('[data-block-id]');
  const classCounts = {};
  for (const b of blocks) {
    // Normalize: keep notion-* tokens only (drop layout/utility classes)
    const tokens = (b.className || '').split(/\s+/).filter((c) => c.startsWith('notion-'));
    const key = tokens.sort().join(' ');
    classCounts[key] = (classCounts[key] || 0) + 1;
  }
  // Sort by count desc
  const ranked = Object.entries(classCounts).sort((a, b) => b[1] - a[1]);

  // For each distinct class signature, capture one sample outerHTML (truncated)
  const seen = new Set();
  const samples = [];
  for (const b of blocks) {
    const tokens = (b.className || '').split(/\s+/).filter((c) => c.startsWith('notion-'));
    const key = tokens.sort().join(' ');
    if (seen.has(key)) continue;
    seen.add(key);
    samples.push({
      classes: key,
      tag: b.tagName,
      outerHTMLSample: b.outerHTML.slice(0, 400),
      textSample: (b.textContent || '').slice(0, 100),
    });
  }

  return {
    totalBlocks: blocks.length,
    distinctClasses: ranked.length,
    inventory: ranked.map(([cls, n]) => ({ classes: cls, count: n })),
    samplesByClass: samples,
  };
});

console.log(JSON.stringify(result, null, 2));
await browser.close();
