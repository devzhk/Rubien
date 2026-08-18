import assert from 'node:assert/strict';
import test from 'node:test';
import Defuddle from 'defuddle/full';
import { parseHTML } from 'linkedom';

import { rubienNormalizeCodeBlocks } from '../src/code-blocks.js';

test('wraps rich-editor multiline code without changing inline or semantic code', () => {
  const { document } = parseHTML(`
    <html>
      <head><title>Code block fixture</title></head>
      <body>
        <article>
          <p>This paragraph makes the fixture extractable.</p>
          <code class="rde-code" data-language="javascript">
            <span>first &lt; value</span><br><span>second line</span>
          </code>
          <p>Run <code>swift test</code> after changing it.</p>
          <pre><code>already semantic</code></pre>
        </article>
      </body>
    </html>
  `);

  const clone = document.cloneNode(true);
  const normalized = rubienNormalizeCodeBlocks(document, clone);

  assert.equal(normalized, 1);
  assert.equal(document.querySelector('code.rde-code').parentElement.tagName, 'ARTICLE');
  const richCode = clone.querySelector('code.rde-code');
  assert.equal(richCode.parentElement.tagName, 'PRE');
  assert.ok(richCode.classList.contains('language-javascript'));
  assert.equal(clone.querySelector('p code').parentElement.tagName, 'P');
  assert.equal(clone.querySelectorAll('pre').length, 2);

  const result = new Defuddle(clone, { url: 'https://example.com/article' }).parse();
  const extracted = parseHTML(result.content).document;
  const blocks = extracted.querySelectorAll('pre');
  assert.equal(blocks.length, 2, result.content);
  assert.match(blocks[0].textContent, /first < value\s*second line/);
  assert.equal(extracted.querySelector('p code').textContent, 'swift test');
});

test('wraps a bare code element carrying a rich-editor line gutter', () => {
  const { document } = parseHTML(`
    <article>
      <p>Introductory text.</p>
      <code data-gutter="1">single line block</code>
    </article>
  `);
  const clone = document.cloneNode(true);

  assert.equal(rubienNormalizeCodeBlocks(document, clone), 1);
  assert.equal(clone.querySelector('pre > code').textContent, 'single line block');
  assert.equal(document.querySelector('pre'), null);
});

test('uses connected source styles while changing only the extraction clone', () => {
  const { document } = parseHTML(`
    <article>
      <p>Introductory text.</p>
      <code class="editor-block">single line block</code>
      <p>Keep <code>inline-code</code> inline.</p>
    </article>
  `);
  const clone = document.cloneNode(true);
  document.defaultView.getComputedStyle = (element) => ({
    display: element.classList.contains('editor-block') ? 'block' : 'inline',
  });

  assert.equal(rubienNormalizeCodeBlocks(document, clone), 1);
  assert.equal(clone.querySelector('pre > code.editor-block').textContent, 'single line block');
  assert.equal(clone.querySelector('p code').parentElement.tagName, 'P');
  assert.equal(document.querySelector('pre'), null);
});
