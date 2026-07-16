import { afterEach, describe, expect, it, vi } from "vitest";
import { resolveLocator } from "../lib/metadata";

function jsonResponse(body: unknown) {
  return { ok: true, json: async () => body } as Response;
}

function textResponse(body: string) {
  return { ok: true, text: async () => body } as Response;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("resolveLocator", () => {
  it("rejects empty input", async () => {
    await expect(resolveLocator("   ")).rejects.toThrow();
  });

  it("resolves a DOI via Crossref", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        message: {
          title: ["Portable Reference Managers"],
          author: [{ given: "Jane", family: "Smith" }],
          issued: { "date-parts": [[2024, 5, 1]] },
          "container-title": ["Journal of Local Software"],
          type: "journal-article",
          URL: "https://doi.org/10.1234/rubien.2024"
        }
      })
    );
    vi.stubGlobal("fetch", fetchMock);

    const ref = await resolveLocator("10.1234/rubien.2024");
    expect(fetchMock).toHaveBeenCalledWith(expect.stringContaining("api.crossref.org"));
    expect(ref).toMatchObject({
      title: "Portable Reference Managers",
      year: 2024,
      issuedMonth: 5,
      journal: "Journal of Local Software",
      referenceType: "Journal Article",
      metadataSource: "doi"
    });
    expect(ref.authors).toEqual([{ given: "Jane", family: "Smith" }]);
  });

  it("resolves an arXiv id via the arXiv API", async () => {
    const atom = `<?xml version="1.0"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
          <title>Attention Is All You Need</title>
          <summary>A paper about transformers.</summary>
          <published>2017-06-12T00:00:00Z</published>
          <author><name>Ashish Vaswani</name></author>
        </entry>
      </feed>`;
    const fetchMock = vi.fn(async () => textResponse(atom));
    vi.stubGlobal("fetch", fetchMock);

    const ref = await resolveLocator("arXiv:1706.03762");
    expect(fetchMock).toHaveBeenCalledWith(expect.stringContaining("export.arxiv.org"));
    expect(ref).toMatchObject({
      title: "Attention Is All You Need",
      year: 2017,
      journal: "arXiv",
      metadataSource: "arxiv"
    });
    expect(ref.authors[0]).toEqual({ given: "Ashish", family: "Vaswani" });
    expect(ref.url).toBe("https://arxiv.org/abs/1706.03762");
  });

  it("treats a bare http(s) URL as a web page without fetching", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const ref = await resolveLocator("https://example.com/article");
    expect(fetchMock).not.toHaveBeenCalled();
    expect(ref).toMatchObject({
      url: "https://example.com/article",
      referenceType: "Web Page",
      metadataSource: "manual"
    });
  });
});
