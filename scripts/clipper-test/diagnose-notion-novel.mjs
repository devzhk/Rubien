// Get outerHTML samples of specific Notion block types so we can
// derive selectors for handlers. Driven by block-class arg.

import { webkit } from 'playwright';

const URL = process.argv[2];
const TARGETS = (process.argv[3] || 'notion-callout-block,notion-toggle-block,notion-embed-block,notion-header-block').split(',');

const browser = await webkit.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await context.newPage();
await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 90_000 });

let blockCount = 0;
for (let i = 0; i < 45; i++) {
  blockCount = await page.evaluate(() => document.querySelectorAll('[data-block-id]').length);
  if (blockCount > 50) break;
  await new Promise((r) => setTimeout(r, 1_000));
}

const result = await page.evaluate((targets) => {
  const out = {};
  for (const cls of targets) {
    const el = document.querySelector('div.' + cls + '[data-block-id]');
    if (!el) { out[cls] = null; continue; }
    out[cls] = {
      tag: el.tagName,
      class: el.className,
      dataAttrs: Array.from(el.attributes).filter(a => a.name.startsWith('data-')).map(a => `${a.name}="${a.value.slice(0,80)}"`),
      textSample: (el.textContent || '').slice(0, 200),
      // Larger sample so we can see all the nested structure
      outerHTMLSample: el.outerHTML.slice(0, 2500),
      // Specifically: what's the leaf content path? Does it have its own data-content-editable-leaf?
      hasContentLeaf: !!el.querySelector('[data-content-editable-leaf="true"]'),
      leafText: (() => {
        const leaf = el.querySelector('[data-content-editable-leaf="true"]');
        return leaf ? (leaf.textContent || '').slice(0, 200) : null;
      })(),
      // For embeds: capture iframe / src details
      iframe: (() => {
        const f = el.querySelector('iframe');
        return f ? { src: f.getAttribute('src'), title: f.getAttribute('title') } : null;
      })(),
      img: (() => {
        const i = el.querySelector('img');
        return i ? { src: i.getAttribute('src'), alt: i.getAttribute('alt') } : null;
      })(),
    };
  }
  return out;
}, TARGETS);

console.log(JSON.stringify(result, null, 2));
await browser.close();
