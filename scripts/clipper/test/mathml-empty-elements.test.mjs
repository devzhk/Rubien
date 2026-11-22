import assert from 'node:assert/strict';
import test from 'node:test';
import Defuddle from 'defuddle/full';
import { parseHTML } from 'linkedom';

import { rubienPreserveMathJaxV2Latex } from '../src/mathjax-v2.js';

// MathJax v2 renders an `aligned` block with `\tag{6}` as an mlabeledtr around
// a `columnalign="right left"` mtable. Its MathML relies on textless elements:
// an empty first <mtd> holds the left column of a continuation row, an empty
// <mi> precedes each `&=`, and \qquad becomes <mspace width="2em">. Defuddle
// 0.18.1 deleted every textless element outside its allow list, so rows
// collapsed to one cell (shifting a column) and all spacing disappeared.
const latex = String.raw`\begin{equation}\begin{aligned}
L(\theta) &= x\qquad\text{loss} \\
&\geq y
\end{aligned}\tag{6}\end{equation}`;

const assistiveMathML = `
  <math xmlns="http://www.w3.org/1998/Math/MathML" display="block">
    <mtable displaystyle="true">
      <mlabeledtr>
        <mtd id="mjx-eqn-6"><mtext>(6)</mtext></mtd>
        <mtd>
          <mtable columnalign="right left" rowspacing="3pt" columnspacing="0em" displaystyle="true">
            <mtr>
              <mtd><mi>L</mi><mo stretchy="false">(</mo><mi>θ</mi><mo stretchy="false">)</mo></mtd>
              <mtd><mi></mi><mo>=</mo><mi>x</mi><mspace width="2em"></mspace><mtext>loss</mtext></mtd>
            </mtr>
            <mtr>
              <mtd></mtd>
              <mtd><mi></mi><mo>≥</mo><mi>y</mi></mtd>
            </mtr>
          </mtable>
        </mtd>
      </mlabeledtr>
    </mtable>
  </math>`;

test('Defuddle keeps empty MathML cells, identifiers and spacing in aligned equations', () => {
  const { document } = parseHTML(`
    <html>
      <head><title>MathML fixture</title></head>
      <body>
        <article>
          <p>This introductory paragraph gives Defuddle article content.</p>
          <div class="MathJax_Display" style="text-align: center;">
            <span class="MathJax" id="MathJax-Element-29-Frame" tabindex="0" role="presentation">
              <nobr aria-hidden="true"><span class="math" id="MathJax-Span-1"><span class="mi">L</span></span></nobr>
              <span class="MJX_Assistive_MathML MJX_Assistive_MathML_Block" role="presentation">${assistiveMathML}</span>
            </span>
          </div>
          <script type="math/tex; mode=display" id="MathJax-Element-29">${latex}</script>
          <p>This trailing paragraph completes the extraction fixture.</p>
        </article>
      </body>
    </html>
  `);

  rubienPreserveMathJaxV2Latex(document);
  const result = new Defuddle(document, { url: 'https://example.com/article' }).parse();
  const extracted = parseHTML(result.content).document.querySelectorAll('math');

  assert.equal(extracted.length, 1);
  const math = extracted[0];
  assert.equal(math.getAttribute('data-latex'), latex);
  assert.match(math.textContent, /\(6\)/);

  const alignedTable = math.querySelector('mtable[columnalign]');
  assert.ok(alignedTable, 'the aligned mtable survives');
  const rows = Array.from(alignedTable.children).filter((el) => el.localName === 'mtr');
  assert.equal(rows.length, 2);
  for (const row of rows) {
    const cells = Array.from(row.children).filter((el) => el.localName === 'mtd');
    assert.equal(cells.length, 2, 'each aligned row keeps its left and right cells');
  }
  assert.equal(rows[1].children[0].childNodes.length, 0, 'the continuation row keeps its empty left cell');
  assert.equal(alignedTable.querySelectorAll('mi:empty').length, 2);

  const spaces = Array.from(alignedTable.querySelectorAll('mspace'));
  assert.deepEqual(spaces.map((el) => el.getAttribute('width')), ['2em']);
});
