#if os(macOS)
import Foundation
import JavaScriptCore
import XCTest
@testable import Rubien

final class WebReaderMathRenderingTests: XCTestCase {
    func testAutoRenderConfigurationIncludesKatexDisplayEnvironments() {
        let expectedEnvironments = [
            "equation", "equation*", "align", "align*", "alignat", "alignat*",
            "gather", "gather*", "CD",
        ]

        XCTAssertEqual(WebReaderMathRendering.displayEnvironments, expectedEnvironments)

        let javaScript = WebReaderMathRendering.autoRenderDelimiterEntriesJavaScript
        for environment in expectedEnvironments {
            XCTAssertTrue(
                javaScript.contains(#"left: '\\begin{\#(environment)}'"#),
                "Missing opening delimiter for \(environment)"
            )
            XCTAssertTrue(
                javaScript.contains(#"right: '\\end{\#(environment)}'"#),
                "Missing closing delimiter for \(environment)"
            )
        }
    }

    func testAutoRenderConfigurationKeepsLegacyTextDelimiters() {
        let javaScript = WebReaderMathRendering.autoRenderDelimiterEntriesJavaScript

        XCTAssertTrue(javaScript.contains("left: '$$'"))
        XCTAssertTrue(javaScript.contains("left: '$'"))
        XCTAssertTrue(javaScript.contains(#"left: '\\['"#))
        XCTAssertTrue(javaScript.contains(#"left: '\\('"#))
    }

    func testAutoRenderConfigurationDoesNotDescendIntoNativeMathML() {
        XCTAssertTrue(WebReaderMathRendering.autoRenderIgnoredTags.contains("math"))
        XCTAssertTrue(
            WebReaderMathRendering.autoRenderIgnoredTagEntriesJavaScript.contains("'math'")
        )
    }

    func testAutoRenderConfigurationDecodesToSingleBackslashRuntimeDelimiters() throws {
        let context = try XCTUnwrap(JSContext())
        let expression = "JSON.stringify([\(WebReaderMathRendering.autoRenderDelimiterEntriesJavaScript)])"
        let value = context.evaluateScript(expression)

        XCTAssertNil(context.exception)
        let json = try XCTUnwrap(value?.toString())
        let delimiters = try JSONDecoder().decode([Delimiter].self, from: Data(json.utf8))

        XCTAssertEqual(
            delimiters.first(where: { $0.left == #"\begin{equation}"# }),
            Delimiter(left: #"\begin{equation}"#, right: #"\end{equation}"#, display: true)
        )
        XCTAssertEqual(
            delimiters.first(where: { $0.left == #"\("# }),
            Delimiter(left: #"\("#, right: #"\)"#, display: false)
        )
    }

    func testLegacyDisplayMathNormalizationBridgesHTMLBreakInsideEnvironment() {
        let html = #"<p>before<br> \begin{equation}a \\ <br class="source-break" /> b\end{equation} <br>after</p>"#

        let normalized = WebReaderMathRendering.normalizingLegacyDisplayMath(in: html)

        let expectedMath = #"\begin{equation}a \\ "# + "\n" + #" b\end{equation}"#
        XCTAssertTrue(normalized.contains(expectedMath))
        XCTAssertTrue(normalized.hasPrefix("<p>before<br> "))
        XCTAssertTrue(normalized.hasSuffix(" <br>after</p>"))
        XCTAssertFalse(normalized.contains("source-break"))
    }

    func testLegacyDisplayMathNormalizationLeavesBreaksOutsideEnvironmentUntouched() {
        let html = #"<p>\begin{itemize}a<br>b\end{itemize}</p>"#

        XCTAssertEqual(WebReaderMathRendering.normalizingLegacyDisplayMath(in: html), html)
    }

    func testLegacyDisplayMathNormalizationConsumesQuotedGreaterThanInBreakAttributes() {
        let html = #"<p>\begin{equation}a<br title="> <em>must stay inert</em>" data-note='x > y'>b\end{equation}</p>"#

        let normalized = WebReaderMathRendering.normalizingLegacyDisplayMath(in: html)

        XCTAssertEqual(normalized, #"<p>\begin{equation}a"# + "\n" + #"b\end{equation}</p>"#)
        XCTAssertFalse(normalized.contains("<em>"))
        XCTAssertFalse(normalized.contains("must stay inert"))
    }

    func testLegacyDisplayMathNormalizationLeavesBreakLikeCustomElementsUntouched() {
        let inputs = [
            #"<p>\begin{equation}a<br-custom>b\end{equation}</p>"#,
            #"<p>\begin{equation}a<br"# + "\u{00A0}" + #"custom>b\end{equation}</p>"#,
        ]

        for html in inputs {
            XCTAssertEqual(WebReaderMathRendering.normalizingLegacyDisplayMath(in: html), html)
        }
    }

    func testLatexPreprocessorRemovesNonvisualLabelsOnly() throws {
        let context = try XCTUnwrap(JSContext())
        let script = """
        \(WebReaderMathRendering.latexPreprocessorFunctionJavaScript)
        JSON.stringify([
          rubienPrepareLatexForRendering('\\\\begin{equation}x\\\\label{eq:x}\\\\end{equation}'),
          rubienPrepareLatexForRendering('\\\\text{label remains}\\\\ref{eq:x}'),
          rubienPrepareLatexForRendering('x\\\\label {eq:spaced} + y')
        ]);
        """

        let value = context.evaluateScript(script)

        XCTAssertNil(context.exception)
        let json = try XCTUnwrap(value?.toString())
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(json.utf8)),
            [#"\begin{equation}x\end{equation}"#, #"\text{label remains}\ref{eq:x}"#, "x + y"]
        )
    }

    func testLossyMathMLConversionGetsRepairedAndKeepsItsEquationLabel() throws {
        let results = try evaluateJSONArray(of: String?.self, #"""
        [
          rubienNumberLatexFromMathML(
            rubienPrepareLatexForRendering(
              '(\\text{4}) \\underset{x , y}{min} a x^{- p} + b y^{- q} \\text{s}.\\text{t}. x + y = 1'),
            mathWithRows(['(4)'])),
          rubienNumberLatexFromMathML('\\begin{equation}\\min_{x,y} f(x)\\end{equation}', mathWithRows(['(4)'])),
          rubienNumberLatexFromMathML('\\begin{equation}x\\end{equation}', flattenedMath('(1)')),
          rubienNumberLatexFromMathML('\\begin{equation}x\\end{equation}', mathWithRows(['[4]']))
        ]
        """#, prelude: Self.mathMLStubs)

        XCTAssertEqual(results, [
            #"\underset{x , y}{\min} a x^{- p} + b y^{- q} \qquad\text{s.t.}\qquad x + y = 1\tag{4}"#,
            #"\begin{equation*}\min_{x,y} f(x)\tag{4}\end{equation*}"#,
            #"\begin{equation*}x\tag{1}\end{equation*}"#,
            nil,
        ])
    }

    func testDataLatexRerenderOnlyReplacesSuccessfulKatexOutput() throws {
        let context = try XCTUnwrap(JSContext())
        let script = """
        \(WebReaderMathRendering.latexPreprocessorFunctionJavaScript)
        function attemptRender(shouldThrow) {
          const mathEl = {
            replaced: false,
            replaceWith: function (_) { this.replaced = true; }
          };
          const span = {};
          const latex = shouldThrow ? 'invalid' : 'valid';
          const displayMode = false;
          const katex = {
            render: function (_, _, options) {
              if (shouldThrow && options.throwOnError) {
                throw new Error('invalid preserved LaTeX');
              }
            }
          };
          \(WebReaderMathRendering.dataLatexRenderAttemptJavaScript)
          return mathEl.replaced;
        }
        JSON.stringify([attemptRender(false), attemptRender(true)]);
        """

        let value = context.evaluateScript(script)

        XCTAssertNil(context.exception)
        let json = try XCTUnwrap(value?.toString())
        XCTAssertEqual(try JSONDecoder().decode([Bool].self, from: Data(json.utf8)), [true, false])
    }

    func testDataLatexRerenderKeepsSemanticMathMLUnlessColorStylingNeedsKatex() throws {
        let context = try XCTUnwrap(JSContext())
        let script = """
        \(WebReaderMathRendering.latexPreprocessorFunctionJavaScript)
        function attemptRender(latex, children) {
          const mathEl = {
            children: children,
            replaced: false,
            replaceWith: function (_) { this.replaced = true; }
          };
          const span = {};
          const displayMode = true;
          let katexCalls = 0;
          const katex = {
            render: function () { katexCalls++; }
          };
          \(WebReaderMathRendering.dataLatexRenderAttemptJavaScript)
          return [mathEl.replaced ? 1 : 0, katexCalls];
        }
        JSON.stringify([
          attemptRender('F_{arch} sim N^{-gamma}', [{ localName: 'mtable' }]),
          attemptRender('\\\\textcolor{red}{x}', [{ localName: 'mrow' }]),
          attemptRender('x + y', [])
        ]);
        """

        let value = context.evaluateScript(script)

        XCTAssertNil(context.exception)
        let json = try XCTUnwrap(value?.toString())
        XCTAssertEqual(
            try JSONDecoder().decode([[Int]].self, from: Data(json.utf8)),
            [[0, 0], [1, 1], [1, 1]]
        )
    }

    func testAuthorTeXDetectionRejectsLatexRebuiltFromMathML() throws {
        let results = try evaluateJSONArray(of: Bool.self, #"""
        [
          rubienLatexIsAuthorSource('\\begin{equation}x\\end{equation}'),
          rubienLatexIsAuthorSource('\\begin{gather*}a \\\\ b\\end{gather*}'),
          rubienLatexIsAuthorSource('\\begin{aligned}a &= b\\end{aligned}'),
          rubienLatexIsAuthorSource('x \\tag{2}'),
          rubienLatexIsAuthorSource('(\\text{6}) \\begin{matrix}L & = A \\\\ & + B\\end{matrix}'),
          rubienLatexIsAuthorSource('L & = A \\\\ & + B'),
          rubienLatexIsAuthorSource('(\\text{1}) a x^{p} \\geq 2')
        ]
        """#)

        XCTAssertEqual(results, [true, true, true, true, false, false, false])
    }

    func testEquationLabelsBecomeExplicitTagsInStarredEnvironments() throws {
        let results = try evaluateJSONArray(of: String?.self, #"""
        [
          rubienApplyEquationLabels(
            '\\begin{equation}\\begin{aligned}L &= A \\\\ &\\qquad + B\\end{aligned}\\end{equation}', ['6']),
          rubienApplyEquationLabels(
            '\\begin{gather}a \\\\ b \\\\[3pt] \\begin{cases} c \\\\ d \\end{cases}\\end{gather}',
            ['21', '22', '23']),
          rubienApplyEquationLabels('\\begin{align}a &= b \\notag \\\\ &= c\\end{align}', [null, '3']),
          rubienApplyEquationLabels('\\begin{align}a &= b \\\\ &= c\\end{align}', []),
          rubienApplyEquationLabels('\\begin{gather}a \\\\ b \\\\ \\end{gather}', ['1', '2']),
          rubienApplyEquationLabels('\\begin{alignat}{2}a &= b \\tag{A}\\end{alignat}', ['A']),
          rubienApplyEquationLabels('\\begin{aligned}a &= b\\end{aligned}', ['9']),
          rubienApplyEquationLabels(
            '\\begin{align}a &= [0,1) \\\\ [1,2) &= b \\\\ c &= d]\\end{align}', ['1', '2', '3']),
          rubienApplyEquationLabels('\\begin{gather}a \\\\ b\\end{gather}', ['1']),
          rubienApplyEquationLabels('\\begin{aligned}a \\\\ b\\end{aligned}', ['1', '2']),
          rubienApplyEquationLabels('\\begin{align}a &= b \\\\ c &= d\\end{align}.', []),
          rubienApplyEquationLabels('% main result\n\\begin{equation}x\\end{equation}', [])
        ]
        """#)

        XCTAssertEqual(results, [
            #"\begin{equation*}\begin{aligned}L &= A \\ &\qquad + B\end{aligned}\tag{6}\end{equation*}"#,
            #"\begin{gather*}a \tag{21}\\ b \tag{22}\\[3pt] \begin{cases} c \\ d \end{cases}\tag{23}\end{gather*}"#,
            #"\begin{align*}a &= b \notag \\ &= c\tag{3}\end{align*}"#,
            #"\begin{align*}a &= b \\ &= c\end{align*}"#,
            #"\begin{gather*}a \tag{1}\\ b \tag{2}\end{gather*}"#,
            #"\begin{alignat*}{2}a &= b \tag{A}\end{alignat*}"#,
            #"\begin{aligned}a &= b\end{aligned}\tag{9}"#,
            #"\begin{align*}a &= [0,1) \tag{1}\\ [1,2) &= b \tag{2}\\ c &= d]\tag{3}\end{align*}"#,
            nil,
            nil,
            nil,
            nil,
        ])
    }

    func testDataLatexRerenderMovesSourceEquationLabelsIntoKatex() throws {
        let results = try evaluateJSONArray(of: [String?].self, #"""
        (function () {
          function attemptRender(latex, mathEl, renderedText) {
            mathEl.replaced = false;
            mathEl.replaceWith = function (_) { this.replaced = true; };
            const span = {
              querySelector: function () {
                return { textContent: renderedText, querySelectorAll: function () { return []; } };
              }
            };
            const displayMode = true;
            let rendered = null;
            const katex = { render: function (tex) { rendered = tex; } };
            \#(WebReaderMathRendering.dataLatexRenderAttemptJavaScript)
            return [mathEl.replaced ? 'replaced' : 'native', rendered];
          }
          const authorTeX = '\\begin{equation}\\begin{aligned}L &= A\\end{aligned}\\label{eq:x}\\end{equation}';
          return [
            attemptRender(authorTeX, mathWithRows(['(6)'], '(6)L=A'), 'L=A'),
            attemptRender(authorTeX, flattenedMath('(6)', 'L=A(6)'), 'L=A'),
            attemptRender('(\\text{6}) \\begin{matrix}L & = A\\end{matrix}', mathWithRows(['(6)'], '(6)L=A'), 'L=A'),
            attemptRender(authorTeX, mathWithRows([''], 'L=A'), 'L=A'),
            attemptRender('\\begin{equation}\\P(X)\\end{equation}', mathWithRows(['(1)'], '(1)P(X)'), '¶(X)'),
            attemptRender('% note\n\\begin{equation}x\\end{equation}', mathWithRows([], 'x'), 'x')
          ];
        })()
        """#, prelude: Self.mathMLStubs)

        let tagged = #"\begin{equation*}\begin{aligned}L &= A\end{aligned}\tag{6}\end{equation*}"#
        XCTAssertEqual(results, [
            ["replaced", tagged],
            ["replaced", tagged],
            ["native", nil],
            ["native", nil],
            ["native", #"\begin{equation*}\P(X)\tag{1}\end{equation*}"#],
            ["native", nil],
        ])
    }

    func testBundledKatexRendersTransferredEquationLabelsWithoutAutoNumbers() throws {
        let katexURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Rubien/Resources/katex.min.js")
        let rendered = try evaluateJSONArray(of: Rendered.self, #"""
        [
          ['\\begin{equation}\\begin{aligned}L &= A \\\\ &\\qquad + B\\end{aligned}\\end{equation}', ['6']],
          ['\\begin{gather}a \\\\ b \\\\ c\\end{gather}', ['21', null, '23']]
        ].map(function (example) {
          const tex = rubienApplyEquationLabels(example[0], example[1]);
          const html = katex.renderToString(tex, { displayMode: true, throwOnError: true });
          const visible = html.slice(html.indexOf('katex-html'));
          const tags = visible.slice(visible.indexOf('class="tag"'))
            .replace(/^[^>]*>/, '').replace(/<[^>]+>/g, '')
            .split(String.fromCharCode(0x200b)).join('');
          return { tags: tags, autoNumbers: (visible.match(/class="eqn-num"/g) || []).length };
        })
        """#, prelude: try String(contentsOf: katexURL, encoding: .utf8))

        XCTAssertEqual(rendered, [Rendered(tags: "(6)", autoNumbers: 0), Rendered(tags: "(21)(23)", autoNumbers: 0)])
    }

    /// Minimal stand-ins for preserved MathML: a table whose rows are numbered
    /// with `<mlabeledtr>` (MathJax's assistive MathML), and the one-row form
    /// Defuddle 0.19+ flattens to `<mrow>…<mspace width="2em"/>(n)</mrow>`.
    private static let mathMLStubs = #"""
    function mathWithRows(labels, text) {
      const table = { localName: 'mtable', children: [] };
      labels.forEach(function (label) {
        table.children.push({
          localName: label === null ? 'mtr' : 'mlabeledtr',
          parentElement: table,
          firstElementChild: { textContent: label }
        });
      });
      return {
        children: [table], firstElementChild: table, textContent: text || '',
        querySelector: function () { return null; },
        querySelectorAll: function (selector) {
          return selector !== 'mlabeledtr' ? [] : table.children.filter(function (row) {
            return row.localName === 'mlabeledtr';
          });
        }
      };
    }
    function flattenedMath(label, text) {
      const spacer = {
        localName: 'mspace', getAttribute: function (name) { return name === 'width' ? '2em' : null; }
      };
      const row = {
        localName: 'mrow',
        lastElementChild: { localName: 'mtext', textContent: label, previousElementSibling: spacer }
      };
      return {
        children: [row], firstElementChild: row, textContent: text || '',
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; }
      };
    }
    """#

    private func evaluateJSONArray<Element: Decodable>(
        of _: Element.Type,
        _ expression: String,
        prelude: String = ""
    ) throws -> [Element] {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(prelude)
        let value = context.evaluateScript("""
        \(WebReaderMathRendering.latexPreprocessorFunctionJavaScript)
        JSON.stringify(\(expression));
        """)
        XCTAssertNil(context.exception)
        let json = try XCTUnwrap(value?.toString())
        return try JSONDecoder().decode([Element].self, from: Data(json.utf8))
    }

    private struct Rendered: Decodable, Equatable {
        let tags: String
        let autoNumbers: Int
    }

    private struct Delimiter: Codable, Equatable {
        let left: String
        let right: String
        let display: Bool
    }
}
#endif
