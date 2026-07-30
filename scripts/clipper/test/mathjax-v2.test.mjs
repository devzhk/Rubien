import assert from 'node:assert/strict';
import test from 'node:test';
import Defuddle from 'defuddle/full';
import { parseHTML } from 'linkedom';

import { rubienPreserveMathJaxV2Latex } from '../src/mathjax-v2.js';

function element({ matches = false, closest = null } = {}) {
  return {
    attributes: new Map(),
    setAttribute(name, value) {
      this.attributes.set(name, value);
    },
    matches() {
      return matches;
    },
    closest() {
      return closest;
    },
  };
}

test('preserves MathJax v2 source on the rendered frame and display container', () => {
  const display = element();
  const frame = element({ closest: display });
  const latex = String.raw`\begin{equation}\min_{x,y} ax^{-p}\qquad\text{s.t.}\end{equation}`;
  const script = {
    id: 'MathJax-Element-4',
    textContent: latex,
    previousElementSibling: display,
    getAttribute(name) {
      return name === 'type' ? 'math/tex; mode=display' : this.id;
    },
  };
  const doc = {
    querySelectorAll() {
      return [script];
    },
    getElementById(id) {
      return id === 'MathJax-Element-4-Frame' ? frame : null;
    },
  };

  rubienPreserveMathJaxV2Latex(doc);

  assert.equal(frame.attributes.get('data-latex'), latex);
  assert.equal(display.attributes.get('data-latex'), latex);
});

test('falls back to the preceding MathJax frame when the script has no id', () => {
  const frame = element({ matches: true });
  const script = {
    id: '',
    textContent: String.raw`\min_x f(x)`,
    previousElementSibling: frame,
    getAttribute(name) {
      return name === 'type' ? 'math/tex' : '';
    },
  };
  const doc = {
    querySelectorAll() {
      return [script];
    },
    getElementById() {
      return null;
    },
  };

  rubienPreserveMathJaxV2Latex(doc);

  assert.equal(frame.attributes.get('data-latex'), script.textContent);
});

test('Defuddle retains the original MathJax v2 TeX instead of reconstructing it', () => {
  const latex =
    String.raw`\begin{equation}\min_{x,y} f(x)\qquad\text{s.t.}\end{equation}`;
  const { document } = parseHTML(`
    <html>
      <head><title>MathJax fixture</title></head>
      <body>
        <article>
          <p>This introductory paragraph gives Defuddle article content.</p>
          <div class="MathJax_Display">
            <span
              class="MathJax"
              id="MathJax-Element-4-Frame"
              data-mathml="&lt;math display=&quot;block&quot;&gt;&lt;mi&gt;x&lt;/mi&gt;&lt;/math&gt;"
            ></span>
          </div>
          <script type="math/tex; mode=display" id="MathJax-Element-4">${latex}</script>
          <p>This trailing paragraph completes the extraction fixture.</p>
        </article>
      </body>
    </html>
  `);

  rubienPreserveMathJaxV2Latex(document);
  const result = new Defuddle(document, { url: 'https://example.com/article' }).parse();
  const extracted = parseHTML(result.content).document.querySelector('math');

  assert.ok(extracted);
  assert.equal(extracted.getAttribute('data-latex'), latex);
  assert.equal(extracted.getAttribute('display'), 'block');
});
