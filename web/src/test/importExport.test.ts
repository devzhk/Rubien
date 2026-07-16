import { describe, expect, it } from "vitest";
import { renderStoredContent } from "../lib/content";
import { exportBibTeX, exportRIS, parseBibTeX, parseHTMLDocument, parseMarkdownDocument, parseRIS } from "../lib/importExport";
import { customPropertyFromInput, emptyReference, parseAuthors } from "../lib/model";

describe("author parsing", () => {
  it("keeps BibTeX-protected corporate names intact", () => {
    expect(parseAuthors("{International Brain Lab} and Smith, Jane")).toEqual([
      { given: "", family: "International Brain Lab" },
      { given: "Jane", family: "Smith" }
    ]);
  });
});

describe("BibTeX import/export", () => {
  it("imports common article fields", () => {
    const refs = parseBibTeX(`
      @article{smith2024,
        title = {Portable Reference Managers},
        author = {Smith, Jane and Lee, Ken},
        year = {2024},
        journal = {Journal of Local Software},
        volume = {12},
        number = {3},
        pages = {1--9},
        doi = {10.1234/rubien.2024}
      }
    `);

    expect(refs).toHaveLength(1);
    expect(refs[0]).toMatchObject({
      title: "Portable Reference Managers",
      year: 2024,
      journal: "Journal of Local Software",
      referenceType: "Journal Article",
      doi: "10.1234/rubien.2024"
    });
    expect(refs[0].authors).toEqual([
      { given: "Jane", family: "Smith" },
      { given: "Ken", family: "Lee" }
    ]);
  });

  it("exports deterministic citation keys", () => {
    const [ref] = parseBibTeX("@book{key,title={Knowledge},author={Ada Lovelace},year={1843}}");
    expect(exportBibTeX([ref])).toContain("@book{Lovelace1843,");
  });

  it("escapes LaTeX special characters on export and unescapes on re-import", () => {
    const ref = emptyReference({ title: "Cost & Value: 50% off #1_topic", authors: [{ given: "Ada", family: "Lovelace" }] });
    const bib = exportBibTeX([ref]);
    expect(bib).toContain("Cost \\& Value: 50\\% off \\#1\\_topic");
    const [reimported] = parseBibTeX(bib);
    expect(reimported.title).toBe("Cost & Value: 50% off #1_topic");
  });
});

describe("RIS import", () => {
  it("imports RIS journal records", () => {
    const refs = parseRIS(`
TY  - JOUR
AU  - Smith, Jane
TI  - Local-first libraries
PY  - 2025/04/12
JO  - Browser Data
DO  - 10.5555/local
ER  -
`);

    expect(refs[0]).toMatchObject({
      title: "Local-first libraries",
      year: 2025,
      journal: "Browser Data",
      issuedMonth: 4,
      referenceType: "Journal Article"
    });
  });

  it("keeps the final record when the file omits a trailing ER tag", () => {
    const refs = parseRIS(`TY  - JOUR
TI  - First
ER  -
TY  - JOUR
TI  - Second`);
    expect(refs.map((ref) => ref.title)).toEqual(["First", "Second"]);
  });

  it("tolerates trailing whitespace on the TY line", () => {
    const refs = parseRIS("TY  - JOUR \r\nTI  - Padded type\r\nER  -\r\n");
    expect(refs[0].referenceType).toBe("Journal Article");
  });

  it("round-trips a journal ISSN through the RIS SN field", () => {
    const ref = emptyReference({
      title: "Serial",
      referenceType: "Journal Article",
      issn: "1234-5678",
      authors: [{ given: "Jane", family: "Smith" }]
    });
    const [reimported] = parseRIS(exportRIS([ref]));
    expect(reimported.issn).toBe("1234-5678");
    expect(reimported.isbn).toBeUndefined();
  });

  it("drops javascript: URLs on import", () => {
    const [ref] = parseRIS(`TY  - JOUR
TI  - Malicious link
UR  - javascript:alert(document.cookie)
ER  -
`);
    expect(ref.url).toBeUndefined();
  });
});

describe("document imports", () => {
  it("imports Markdown as stored reader content", () => {
    const ref = parseMarkdownDocument("paper-notes.md", "# Paper Notes\n\nUseful **summary**.");
    expect(ref).toMatchObject({
      title: "Paper Notes",
      referenceType: "Markdown",
      webContentFormat: "markdown"
    });
    expect(renderStoredContent(ref)).toContain("<strong>summary</strong>");
  });

  it("imports HTML and sanitizes scripts before rendering", () => {
    const ref = parseHTMLDocument("article.html", "<html><head><title>Article</title></head><body><h1>Body</h1><script>alert(1)</script></body></html>");
    expect(ref.title).toBe("Article");
    expect(ref.metadataSource).toBe("web");
    expect(renderStoredContent(ref)).toContain("Body");
    expect(renderStoredContent(ref)).not.toContain("script");
  });
});

describe("custom properties", () => {
  it("builds typed select properties from comma-separated options", () => {
    const property = customPropertyFromInput("Priority", "singleSelect", "High, Low", 3);
    expect(property).toMatchObject({
      name: "Priority",
      type: "singleSelect",
      sortOrder: 3
    });
    expect(property.options.map((option) => option.value)).toEqual(["High", "Low"]);
  });
});
