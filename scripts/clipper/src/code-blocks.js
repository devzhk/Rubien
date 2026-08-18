// Defuddle distinguishes block code from inline code by HTML structure: a
// block must be `<pre><code>…</code></pre>`. Some rich-text editors instead
// emit a bare `<code>` and rely on site CSS (`display: block`) plus `<br>`
// children for lines. Once the page CSS is gone, Defuddle correctly preserves
// that literal structure, but Rubien can only render it as inline code.
//
// Normalize the cloned extraction document, never the live page. Source and
// target code elements have identical document order immediately after the
// clone, which lets us consult computed style on the connected source element
// while changing only its detached counterpart.
export function rubienNormalizeCodeBlocks(sourceDoc, targetDoc) {
  if (!targetDoc) throw new TypeError('targetDoc is required');
  const sourceCodes = Array.from(sourceDoc.querySelectorAll('code'));
  const targetCodes = Array.from(targetDoc.querySelectorAll('code'));
  const blockDisplays = new Set(['block', 'flex', 'flow-root', 'grid', 'list-item', 'table']);
  let normalized = 0;

  for (let index = 0; index < targetCodes.length; index++) {
    const targetCode = targetCodes[index];
    if (targetCode.closest('pre')) continue;

    const sourceCode = sourceCodes[index] || targetCode;
    const hasLineBreaks = targetCode.querySelector('br') != null;
    const hasLineGutter = targetCode.hasAttribute('data-gutter');
    if (!hasLineBreaks && !hasLineGutter) {
      let display = (sourceCode.style && sourceCode.style.display) || '';
      try {
        const computed = sourceDoc.defaultView && sourceDoc.defaultView.getComputedStyle
          ? sourceDoc.defaultView.getComputedStyle(sourceCode)
          : null;
        if (computed && computed.display) display = computed.display;
      } catch (_) {
        // Detached/test documents may not implement getComputedStyle.
      }
      if (!blockDisplays.has(display)) continue;
    }

    const language = (targetCode.getAttribute('data-language') || '').trim();
    if (/^[a-z0-9_+-]+$/i.test(language) &&
        !Array.from(targetCode.classList).some((name) => name.startsWith('language-'))) {
      targetCode.classList.add('language-' + language);
    }

    const pre = targetDoc.createElement('pre');
    targetCode.replaceWith(pre);
    pre.appendChild(targetCode);
    normalized++;
  }

  return normalized;
}
