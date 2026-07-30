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

    func testLatexPreprocessorRepairsLossyMathMLConversionWithEquationLabel() throws {
        let context = try XCTUnwrap(JSContext())
        let script = #"""
        \#(WebReaderMathRendering.latexPreprocessorFunctionJavaScript)
        const mathEl = {
          querySelectorAll: function (_) {
            return [{ firstElementChild: { textContent: '(4)' } }];
          }
        };
        rubienPrepareLatexForRendering(
          '(\\text{4}) \\underset{x , y}{min} a x^{- p} + b y^{- q} \\text{s}.\\text{t}. x + y = 1',
          mathEl
        );
        """#

        let value = context.evaluateScript(script)

        XCTAssertNil(context.exception)
        let repaired = try XCTUnwrap(value?.toString())
        XCTAssertTrue(repaired.contains(#"\underset{x , y}{\min}"#))
        XCTAssertTrue(repaired.contains(#"\qquad\text{s.t.}\qquad"#))
        XCTAssertTrue(repaired.hasSuffix(#"\tag{4}"#))
        XCTAssertFalse(repaired.hasPrefix(#"(\text{4})"#))
        XCTAssertFalse(repaired.contains(#"{min}"#))
        XCTAssertFalse(repaired.contains(#"\text{s}.\text{t}."#))
    }

    func testLatexPreprocessorRestoresMathMLLabelInsideEquationEnvironment() throws {
        let context = try XCTUnwrap(JSContext())
        let script = #"""
        \#(WebReaderMathRendering.latexPreprocessorFunctionJavaScript)
        const mathEl = {
          querySelectorAll: function (_) {
            return [{ firstElementChild: { textContent: '(4)' } }];
          }
        };
        rubienPrepareLatexForRendering(
          '\\begin{equation}\\min_{x,y} f(x)\\end{equation}',
          mathEl
        );
        """#

        let value = context.evaluateScript(script)

        XCTAssertNil(context.exception)
        XCTAssertEqual(
            value?.toString(),
            #"\begin{equation}\min_{x,y} f(x)\tag{4}\end{equation}"#
        )
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

    private struct Delimiter: Codable, Equatable {
        let left: String
        let right: String
        let display: Bool
    }
}
#endif
