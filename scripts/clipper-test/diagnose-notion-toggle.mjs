// Probe toggle behavior: are children in DOM when collapsed, or only after expand?

import { webkit } from 'playwright';

const URL = process.argv[2] ||
  'https://yaofu.notion.site/Full-Stack-Transformer-Inference-Optimization-Season-2-Deploying-Long-Context-Models-ee25d3a77ba14f73b8ae19147f77d5e2';

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

const collapsedState = await page.evaluate(() => {
  const t = document.querySelector('div.notion-toggle-block[data-block-id]');
  if (!t) return null;
  return {
    outerHTMLLength: t.outerHTML.length,
    innerDataBlockIds: t.querySelectorAll('[data-block-id]').length - 1, // exclude self
    ariaExpanded: t.querySelector('[aria-expanded]')?.getAttribute('aria-expanded'),
    visibleChildText: (() => {
      // Look for any child content beyond the leaf label
      const leaves = t.querySelectorAll('[data-content-editable-leaf="true"]');
      return Array.from(leaves).map(l => (l.textContent || '').slice(0, 60));
    })(),
    fullOuterHTML: t.outerHTML,
  };
});

console.log('=== Collapsed state ===');
if (collapsedState) {
  console.log('outerHTML length:', collapsedState.outerHTMLLength);
  console.log('inner [data-block-id] count (excluding self):', collapsedState.innerDataBlockIds);
  console.log('aria-expanded:', collapsedState.ariaExpanded);
  console.log('all leaf text:', JSON.stringify(collapsedState.visibleChildText));
  console.log('--- full outerHTML ---');
  console.log(collapsedState.fullOuterHTML);
}

// Now try clicking the toggle to expand it
console.log('\n=== Attempting to expand toggle ===');
const clicked = await page.evaluate(() => {
  const t = document.querySelector('div.notion-toggle-block[data-block-id]');
  if (!t) return 'no toggle';
  const button = t.querySelector('[aria-expanded][role="button"]');
  if (!button) return 'no button';
  button.click();
  return 'clicked';
});
console.log('click attempt:', clicked);

// Wait a moment for React to re-render
await new Promise((r) => setTimeout(r, 2000));

const expandedState = await page.evaluate(() => {
  const t = document.querySelector('div.notion-toggle-block[data-block-id]');
  if (!t) return null;
  return {
    outerHTMLLength: t.outerHTML.length,
    innerDataBlockIds: t.querySelectorAll('[data-block-id]').length - 1,
    ariaExpanded: t.querySelector('[aria-expanded]')?.getAttribute('aria-expanded'),
    visibleChildText: (() => {
      const leaves = t.querySelectorAll('[data-content-editable-leaf="true"]');
      return Array.from(leaves).map(l => (l.textContent || '').slice(0, 60));
    })(),
    fullOuterHTML: t.outerHTML,
  };
});

console.log('=== Expanded state ===');
if (expandedState) {
  console.log('outerHTML length:', expandedState.outerHTMLLength);
  console.log('inner [data-block-id] count:', expandedState.innerDataBlockIds);
  console.log('aria-expanded:', expandedState.ariaExpanded);
  console.log('all leaf text:', JSON.stringify(expandedState.visibleChildText));
  if (expandedState.outerHTMLLength > collapsedState.outerHTMLLength + 500) {
    console.log('--- expanded outerHTML (truncated to 3000 chars) ---');
    console.log(expandedState.fullOuterHTML.slice(0, 3000));
  }
}

await browser.close();
