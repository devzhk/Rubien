import { describe, expect, it } from "vitest";
import { renderStoredContent } from "../lib/content";
import { emptyReference } from "../lib/model";

function htmlReference(html: string) {
  return emptyReference({ webContent: html, webContentFormat: "html", referenceType: "Web Page" });
}

describe("renderStoredContent", () => {
  it("never leaves a target=_blank link without noopener (reverse-tabnabbing safe)", () => {
    // This DOMPurify strips `target` outright; the afterSanitizeAttributes hook
    // guarantees the invariant even if a future config re-allows it. Either way,
    // a rendered new-tab link must carry noopener.
    const out = renderStoredContent(htmlReference('<a href="https://example.com" target="_blank">x</a>'));
    expect(out).not.toMatch(/target=["']_blank["'](?![^>]*noopener)/);
  });

  it("strips javascript: hrefs and script tags", () => {
    const out = renderStoredContent(htmlReference('<a href="javascript:alert(1)">x</a><script>alert(1)</script>'));
    expect(out).not.toContain("javascript:");
    expect(out).not.toContain("<script");
  });

  it("escapes text content instead of rendering it as HTML", () => {
    const out = renderStoredContent(
      emptyReference({ webContent: "<b>not bold</b>", webContentFormat: "text", referenceType: "Markdown" })
    );
    expect(out).toContain("&lt;b&gt;");
    expect(out).not.toContain("<b>not bold</b>");
  });
});
