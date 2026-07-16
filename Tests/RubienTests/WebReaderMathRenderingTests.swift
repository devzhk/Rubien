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

    func testDataLatexRerenderOnlyReplacesSuccessfulKatexOutput() throws {
        let context = try XCTUnwrap(JSContext())
        let script = """
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

    private struct Delimiter: Codable, Equatable {
        let left: String
        let right: String
        let display: Bool
    }
}
#endif
