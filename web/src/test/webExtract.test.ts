import { describe, expect, it } from "vitest";
import { extractReadableHTML } from "../lib/webExtract";

const articleHTML = `
<!doctype html>
<html>
  <head>
    <title>Browser Local Article</title>
    <meta property="og:site_name" content="Rubien Journal">
  </head>
  <body>
    <article>
      <h1>Browser Local Article</h1>
      <p>Jane Smith</p>
      <p>This article has enough meaningful prose for a reader extraction pass. It explains
      how local browser storage, saved HTML, annotations, and references can work together
      without requiring cloud synchronization or a platform-specific desktop user interface.</p>
      <p>Additional text keeps the page comfortably above the content threshold.</p>
    </article>
  </body>
</html>`;

describe("web extraction", () => {
  it("extracts readable HTML into a stored web reference", () => {
    const { reference, readerable } = extractReadableHTML(articleHTML, "https://example.org/article");

    expect(readerable).toBe(true);
    expect(reference).toMatchObject({
      title: "Browser Local Article",
      url: "https://example.org/article",
      siteName: "Rubien Journal",
      referenceType: "Web Page",
      metadataSource: "web",
      webContentFormat: "html"
    });
    expect(reference.webContent).toContain("local browser storage");
    expect(reference.abstract).toContain("local browser storage");
  });
});
