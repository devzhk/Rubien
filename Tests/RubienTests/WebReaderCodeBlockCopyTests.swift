#if os(macOS)
import Foundation
import JavaScriptCore
import XCTest
@testable import Rubien

final class WebReaderCodeBlockCopyTests: XCTestCase {
    func testCodeBlockTextPrefersCodeElementAndPreservesWhitespace() throws {
        let context = try XCTUnwrap(JSContext())
        let script = """
        \(WebReaderCodeBlockCopy.javaScript)
        const code = { textContent: 'line 1\\n  line 2\\n' };
        const semanticPre = {
          textContent: 'wrong outer text',
          querySelector: function (_) { return code; }
        };
        const rawPre = {
          textContent: 'raw pre text',
          querySelector: function (_) { return null; }
        };
        JSON.stringify([
          rubienCodeBlockText(semanticPre),
          rubienCodeBlockText(rawPre)
        ]);
        """

        let value = context.evaluateScript(script)

        XCTAssertNil(context.exception)
        let json = try XCTUnwrap(value?.toString())
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(json.utf8)),
            ["line 1\n  line 2\n", "raw pre text"]
        )
    }

    func testEnhancementAddsAccessibleButtonsForSemanticAndBarePre() throws {
        let context = try XCTUnwrap(JSContext())
        let script = """
        \(WebReaderCodeBlockCopy.javaScript)
        const created = [];
        function fakeElement(tag) {
          const element = {
            tagName: tag.toUpperCase(),
            className: '',
            children: [],
            attributes: {},
            classList: {
              contains: function (name) {
                return element.className.split(/\\s+/).includes(name);
              }
            },
            setAttribute: function (name, value) {
              this.attributes[name] = value;
            },
            appendChild: function (child) {
              this.children.push(child);
              child.parentElement = this;
              child.parentNode = this;
            }
          };
          created.push(element);
          return element;
        }
        const document = { createElement: fakeElement };
        const host = {
          wrappers: [],
          classList: { contains: function (_) { return false; } },
          insertBefore: function (wrapper, _) { this.wrappers.push(wrapper); }
        };
        const code = { textContent: 'copy me' };
        const semanticPre = {
          parentNode: host,
          parentElement: host,
          querySelector: function (_) { return code; }
        };
        const rawPre = {
          textContent: 'raw pre text',
          parentNode: host,
          parentElement: host,
          querySelector: function (_) { return null; }
        };
        const article = {
          querySelectorAll: function (_) { return [semanticPre, rawPre]; }
        };

        rubienEnhanceCodeBlocks(article);
        rubienEnhanceCodeBlocks(article);

        const wrapper = host.wrappers[0];
        const button = wrapper.children[1];
        const rawWrapper = host.wrappers[1];
        const rawButton = rawWrapper.children[1];
        JSON.stringify({
          wrapperCount: host.wrappers.length,
          wrapperClass: wrapper.className,
          childCount: wrapper.children.length,
          buttonType: button.type,
          buttonClass: button.className,
          ariaLabel: button.attributes['aria-label'],
          title: button.title,
          hasCopyIcon: button.innerHTML.includes('rubien-code-copy-icon'),
          hasCheckIcon: button.innerHTML.includes('rubien-code-copy-check'),
          rawWrapperClass: rawWrapper.className,
          rawChildCount: rawWrapper.children.length,
          rawAriaLabel: rawButton.attributes['aria-label']
        });
        """

        let value = context.evaluateScript(script)

        XCTAssertNil(context.exception)
        let json = try XCTUnwrap(value?.toString())
        let result = try JSONDecoder().decode(EnhancementResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.wrapperCount, 2)
        XCTAssertEqual(result.wrapperClass, "rubien-code-block")
        XCTAssertEqual(result.childCount, 2)
        XCTAssertEqual(result.buttonType, "button")
        XCTAssertEqual(result.buttonClass, "rubien-code-copy")
        XCTAssertEqual(result.ariaLabel, "Copy code")
        XCTAssertEqual(result.title, "Copy code")
        XCTAssertTrue(result.hasCopyIcon)
        XCTAssertTrue(result.hasCheckIcon)
        XCTAssertEqual(result.rawWrapperClass, "rubien-code-block")
        XCTAssertEqual(result.rawChildCount, 2)
        XCTAssertEqual(result.rawAriaLabel, "Copy code")
    }

    func testFallbackCopyPreservesCodeTextAndRestoresSelection() throws {
        let context = try XCTUnwrap(JSContext())
        let script = """
        \(WebReaderCodeBlockCopy.javaScript)
        let copiedText = null;
        let restoredRange = null;
        const textarea = {
          value: '',
          style: {},
          setAttribute: function () {},
          focus: function () {},
          select: function () {},
          remove: function () { this.wasRemoved = true; }
        };
        const selection = {
          rangeCount: 1,
          getRangeAt: function (_) {
            return { cloneRange: function () { return 'saved-range'; } };
          },
          removeAllRanges: function () { this.wasCleared = true; },
          addRange: function (range) { restoredRange = range; }
        };
        const window = { getSelection: function () { return selection; } };
        const document = {
          body: { appendChild: function (element) { this.appended = element; } },
          createElement: function (_) { return textarea; },
          execCommand: function (command) {
            copiedText = textarea.value;
            return command === 'copy';
          }
        };

        const copied = rubienFallbackCopyText('line 1\\n  line 2\\n');
        JSON.stringify({
          copied: copied,
          copiedText: copiedText,
          removed: textarea.wasRemoved,
          selectionCleared: selection.wasCleared,
          restoredRange: restoredRange
        });
        """

        let value = context.evaluateScript(script)

        XCTAssertNil(context.exception)
        let json = try XCTUnwrap(value?.toString())
        let result = try JSONDecoder().decode(FallbackResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.copied)
        XCTAssertEqual(result.copiedText, "line 1\n  line 2\n")
        XCTAssertTrue(result.removed)
        XCTAssertTrue(result.selectionCleared)
        XCTAssertEqual(result.restoredRange, "saved-range")
    }

    func testStylesReserveCodeSpaceAndProvideKeyboardFocus() {
        let css = WebReaderCodeBlockCopy.styleSheet

        XCTAssertTrue(css.contains("padding-right: 52px !important"))
        XCTAssertTrue(css.contains(".rubien-code-copy:focus-visible"))
        XCTAssertTrue(css.contains(".rubien-code-copy.is-copied"))
        XCTAssertTrue(css.contains("@media (prefers-color-scheme: dark)"))
    }

    private struct EnhancementResult: Decodable {
        let wrapperCount: Int
        let wrapperClass: String
        let childCount: Int
        let buttonType: String
        let buttonClass: String
        let ariaLabel: String
        let title: String
        let hasCopyIcon: Bool
        let hasCheckIcon: Bool
        let rawWrapperClass: String
        let rawChildCount: Int
        let rawAriaLabel: String
    }

    private struct FallbackResult: Decodable {
        let copied: Bool
        let copiedText: String
        let removed: Bool
        let selectionCleared: Bool
        let restoredRange: String
    }
}
#endif
