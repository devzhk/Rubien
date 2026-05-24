// Find Notion's math/equation container shape. Also check whether the
// inline-code selector accidentally matches math containers (selector
// overlap as a possible cause of the math regression after the
// inline-code normalizer landed).

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
  const candidates = [
    'math',
    'annotation',
    '[class*="notion-equation"]',
    '[class*="equation"]',
    '[class*="formula"]',
    '[class*="katex"]',
    '[class*="notion-inline-code-container"]',
    // Critical: does any math container ALSO match my inline-code selector?
    'math[class*="notion-inline-code-container"]',
    'div[class*="notion-inline-code-container"] math',
  ];
  return {
    counts: candidates.reduce((acc, sel) => {
      try { acc[sel] = document.querySelectorAll(sel).length; } catch (_) { acc[sel] = 'err'; }
      return acc;
    }, {}),
    // Sample first math element and its surrounding wrappers
    firstMath: (() => {
      const m = document.querySelector('math');
      if (!m) return null;
      let cur = m;
      const ancestors = [];
      for (let i = 0; i < 5 && cur.parentElement; i++) {
        cur = cur.parentElement;
        ancestors.push({
          tag: cur.tagName,
          class: cur.className,
          dataAttrs: Array.from(cur.attributes).filter(a => a.name.startsWith('data-')).map(a => a.name),
        });
      }
      return {
        outerHTMLSample: m.outerHTML.slice(0, 600),
        ancestors,
      };
    })(),
    // Sample a math equation block (display: block) vs inline
    blockMath: (() => {
      const blocks = document.querySelectorAll('[class*="notion-equation"], [class*="equation_block"]');
      if (blocks.length === 0) return null;
      const b = blocks[0];
      return {
        tag: b.tagName,
        class: b.className,
        dataAttrs: Array.from(b.attributes).filter(a => a.name.startsWith('data-')).map(a => a.name),
        outerHTMLSample: b.outerHTML.slice(0, 600),
      };
    })(),
  };
});

console.log(JSON.stringify(result, null, 2));
await browser.close();
