// Probe Notion's inline-element DOM, nested-list structure, and unseen
// block types. Feeds Task 1 of the unified Notion extractor plan.
//
// Usage:
//   npm run diagnose-notion-inline -- <url-1> [url-2] [...]
// or
//   node diagnose-notion-inline.mjs <url-1> [url-2] [...]

import { webkit } from 'playwright';

const URLS = process.argv.slice(2);
if (URLS.length === 0) {
  URLS.push('https://yumoxu.notion.site/async-grpo-in-the-wild');
  URLS.push('https://yumoxu.notion.site/a-gradient-level-look-at-ppo-grpo-and-cispo');
}

const browser = await webkit.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });

for (const URL of URLS) {
  console.log('\n========================================');
  console.log('URL:', URL);
  console.log('========================================');
  const page = await context.newPage();
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 90_000 });

  let blockCount = 0;
  for (let i = 0; i < 30; i++) {
    blockCount = await page.evaluate(() => document.querySelectorAll('[data-block-id]').length);
    if (blockCount > 0) break;
    await new Promise((r) => setTimeout(r, 1_000));
  }
  if (blockCount === 0) { console.log('did not hydrate'); await page.close(); continue; }

  const probe = await page.evaluate(() => {
    // 1. Top-level Notion block class inventory (all distinct class
    //    signatures on [data-block-id] elements).
    const blocks = document.querySelectorAll('[data-block-id]');
    const classCounts = {};
    for (const b of blocks) {
      const tokens = (b.className || '').split(/\s+/).filter((c) => c.startsWith('notion-'));
      const key = tokens.sort().join(' ');
      classCounts[key] = (classCounts[key] || 0) + 1;
    }
    const inventory = Object.entries(classCounts).sort((a, b) => b[1] - a[1]);

    // 2. Nested list probe: do bulleted_list-blocks contain [data-block-id]
    //    descendants? Same for numbered_list-blocks.
    const nestedListProbe = (() => {
      const out = {};
      for (const cls of ['notion-bulleted_list-block', 'notion-numbered_list-block']) {
        const wrappers = document.querySelectorAll('div.' + cls + '[data-block-id]');
        let withNested = 0;
        let totalNested = 0;
        for (const w of wrappers) {
          const nested = w.querySelectorAll('[data-block-id]');
          // Exclude self
          let count = 0;
          for (const n of nested) if (n !== w) count++;
          if (count > 0) withNested++;
          totalNested += count;
        }
        out[cls] = { wrappers: wrappers.length, withNestedItems: withNested, totalNestedDescendants: totalNested };
      }
      return out;
    })();

    // 3. Inline element shapes: walk a few text/list leaf nodes, dump
    //    each direct child's tag + class + tagName + relevant attrs.
    const inlineShapes = (() => {
      const out = [];
      const textBlocks = document.querySelectorAll('div.notion-text-block[data-block-id], div.notion-bulleted_list-block[data-block-id], div.notion-numbered_list-block[data-block-id]');
      let sampled = 0;
      for (const tb of textBlocks) {
        if (sampled >= 3) break;
        const leaf = tb.querySelector('[data-content-editable-leaf="true"]');
        if (!leaf) continue;
        // Only sample leaves with non-trivial inline content.
        const childTypes = new Set();
        for (const node of leaf.childNodes) {
          if (node.nodeType === 1) childTypes.add(node.tagName + '.' + (node.className || ''));
        }
        if (childTypes.size < 2) continue; // boring text-only leaves
        sampled++;
        const children = [];
        for (const node of leaf.childNodes) {
          if (node.nodeType === 3) {
            const t = (node.nodeValue || '').slice(0, 60);
            if (t.trim()) children.push({ type: 'text', sample: t });
            continue;
          }
          if (node.nodeType !== 1) continue;
          const el = node;
          children.push({
            type: 'element',
            tag: el.tagName,
            class: el.className,
            dataAttrs: Array.from(el.attributes).filter(a => a.name.startsWith('data-')).map(a => a.name),
            style: (el.getAttribute('style') || '').slice(0, 120),
            textSample: (el.textContent || '').slice(0, 60),
            // For potential equation tokens, capture the annotation
            annotationText: (() => {
              const a = el.querySelector && el.querySelector('annotation[encoding="application/x-tex"]');
              return a ? (a.textContent || '').slice(0, 60) : null;
            })(),
          });
        }
        out.push({ blockClass: tb.className, leafChildren: children });
      }
      return out;
    })();

    return { totalBlocks: blocks.length, inventory, nestedListProbe, inlineShapes };
  });

  console.log(JSON.stringify(probe, null, 2));
  await page.close();
}

await browser.close();
