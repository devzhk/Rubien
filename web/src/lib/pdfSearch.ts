export interface ExtractedPDFPage {
  pageNumber: number;
  text: string;
}

export interface PDFSearchMatch {
  pageNumber: number;
  snippet: string;
  index: number;
}

export function searchPDFText(pages: ExtractedPDFPage[], query: string): PDFSearchMatch[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return [];
  const matches: PDFSearchMatch[] = [];
  for (const page of pages) {
    const haystack = page.text.toLowerCase();
    let start = 0;
    while (matches.length < 100) {
      const index = haystack.indexOf(needle, start);
      if (index < 0) break;
      matches.push({
        pageNumber: page.pageNumber,
        index,
        snippet: makeSnippet(page.text, index, query.length)
      });
      start = index + Math.max(needle.length, 1);
    }
  }
  return matches;
}

function makeSnippet(text: string, index: number, length: number): string {
  const start = Math.max(0, index - 56);
  const end = Math.min(text.length, index + length + 84);
  const prefix = start > 0 ? "..." : "";
  const suffix = end < text.length ? "..." : "";
  return `${prefix}${text.slice(start, end).trim()}${suffix}`;
}
