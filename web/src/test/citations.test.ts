import { describe, expect, it } from "vitest";
import { formatBibliography, formatInlineCitation, supportedCitationStyles } from "../lib/citations";
import { emptyReference } from "../lib/model";

const ref = emptyReference({
  title: "Portable Reference Managers",
  authors: [
    { given: "Jane", family: "Smith" },
    { given: "Ken", family: "Lee" }
  ],
  year: 2024,
  journal: "Journal of Local Software",
  volume: "12",
  issue: "3",
  pages: "1-9",
  doi: "10.1234/rubien.2024"
});

describe("inline citations", () => {
  it("numbers IEEE/Vancouver/Nature references", () => {
    expect(formatInlineCitation([ref, ref], "ieee")).toBe("[1, 2]");
    expect(formatInlineCitation([ref, ref], "vancouver")).toBe("[1, 2]");
    expect(formatInlineCitation([ref, ref], "nature")).toBe("1, 2");
  });

  it("uses author-year for APA/Harvard and author for MLA", () => {
    expect(formatInlineCitation([ref], "apa")).toBe("(Smith, 2024)");
    expect(formatInlineCitation([ref], "chicago")).toBe("(Smith 2024)");
    expect(formatInlineCitation([ref], "mla")).toBe("(Smith)");
  });

  it("falls back to n.d. when the year is missing", () => {
    expect(formatInlineCitation([emptyReference({ authors: [{ given: "A", family: "Doe" }] })], "apa")).toBe("(Doe, n.d.)");
  });
});

describe("bibliographies", () => {
  it("produces a non-empty entry for every supported style", () => {
    for (const style of supportedCitationStyles) {
      const entry = formatBibliography(ref, style);
      expect(entry).toContain("Portable Reference Managers");
      expect(entry).toContain("2024");
      expect(entry).toContain("https://doi.org/10.1234/rubien.2024");
    }
  });

  it("renders APA author initials", () => {
    expect(formatBibliography(ref, "apa")).toContain("Smith, J.");
  });

  it("does not throw on an author with an empty given name", () => {
    const corporate = emptyReference({ title: "Report", authors: [{ given: "", family: "International Brain Lab" }], year: 2023 });
    expect(() => formatBibliography(corporate, "apa")).not.toThrow();
    expect(formatBibliography(corporate, "apa")).toContain("International Brain Lab");
  });
});
