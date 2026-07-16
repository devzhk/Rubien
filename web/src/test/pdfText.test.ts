import { describe, expect, it } from "vitest";
import { searchPDFText } from "../lib/pdfSearch";

describe("PDF text search", () => {
  it("returns page-scoped snippets for case-insensitive matches", () => {
    const matches = searchPDFText(
      [
        { pageNumber: 1, text: "Rubien stores references locally." },
        { pageNumber: 2, text: "A local-first PDF reader can search extracted text." }
      ],
      "LOCAL"
    );

    expect(matches).toHaveLength(2);
    expect(matches.map((match) => match.pageNumber)).toEqual([1, 2]);
    expect(matches[1].snippet).toContain("local-first PDF reader");
  });

  it("ignores blank queries", () => {
    expect(searchPDFText([{ pageNumber: 1, text: "No query" }], "   ")).toEqual([]);
  });
});
