import { describe, it, expect } from "vitest";
import {
  ReferenceDTO,
  PropertyDefinitionDTO,
  CitationTextOutput,
  CitationDocxCCOutput,
  CreateReferenceEnvelope,
  DatabaseViewDTO,
  StyleDTO,
  ReadTextPdfOutput,
  ReadTextWebOutput,
  ReadAnnotationItem,
  GrepTextPdfOutput,
  GrepTextWebOutput,
} from "../src/schemas.js";

/**
 * Schema-level regression tests. These pin the Swift-Optional (.optional) vs
 * AlwaysEncodedOptional (.nullable) distinction captured in the plan — a
 * drift here silently breaks every downstream tool result.
 */
describe("zod schemas", () => {
  it("accepts ReferenceDTO with most optional fields omitted", () => {
    // Matches Swift JSONEncoder's default behavior: nil Optionals are absent.
    // `readCount` is non-optional and always present (defaults to 0).
    const minimal = {
      title: "A paper",
      authors: "Alice; Bob",
      referenceType: "Journal Article",
      dateAdded: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      readingStatus: "unread",
      readCount: 0,
      customProperties: [],
    };
    expect(() => ReferenceDTO.parse(minimal)).not.toThrow();
  });

  it("rejects ReferenceDTO with explicit null on a Swift-Optional field", () => {
    // Swift encodes `let year: Int? = nil` as an absent key, NOT `"year": null`.
    // If we start accepting null here we'd be encoding an incorrect contract.
    const withNull = {
      title: "A paper",
      authors: "Alice",
      year: null, // <-- contract violation
      referenceType: "Journal Article",
      dateAdded: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      readingStatus: "unread",
      readCount: 0,
      customProperties: [],
    };
    expect(() => ReferenceDTO.parse(withNull)).toThrow();
  });

  it("accepts ReferenceDTO with lastReadAt set", () => {
    // After a reader open, Swift writes lastReadAt as an ISO string.
    const opened = {
      title: "Opened paper",
      authors: "Alice",
      referenceType: "Journal Article",
      dateAdded: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      readingStatus: "unread",
      lastReadAt: "2026-05-12T15:30:00.000Z",
      readCount: 3,
      customProperties: [],
    };
    expect(() => ReferenceDTO.parse(opened)).not.toThrow();
  });

  it("rejects ReferenceDTO with explicit null lastReadAt", () => {
    // Same Swift-Optional contract as `year`: nil → absent key, not null.
    const withNullRead = {
      title: "A paper",
      authors: "Alice",
      referenceType: "Journal Article",
      dateAdded: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      readingStatus: "unread",
      lastReadAt: null, // <-- contract violation
      readCount: 0,
      customProperties: [],
    };
    expect(() => ReferenceDTO.parse(withNullRead)).toThrow();
  });

  it("rejects ReferenceDTO missing readCount", () => {
    // readCount is required — CLI always emits it (defaults to 0).
    const missingReadCount = {
      title: "A paper",
      authors: "Alice",
      referenceType: "Journal Article",
      dateAdded: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      readingStatus: "unread",
      customProperties: [],
    };
    expect(() => ReferenceDTO.parse(missingReadCount)).toThrow();
  });

  it("accepts ReferenceDTO with siteName set", () => {
    // Web-clipped references emit siteName; PDF-only references omit the key.
    const clipped = {
      title: "On-Policy Distillation",
      authors: "Anonymous",
      url: "https://thinkingmachines.ai/blog/on-policy-distillation/",
      siteName: "thinkingmachines.ai",
      referenceType: "Web Page",
      dateAdded: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      readingStatus: "unread",
      readCount: 0,
      customProperties: [],
    };
    expect(() => ReferenceDTO.parse(clipped)).not.toThrow();
  });

  it("rejects ReferenceDTO with explicit null siteName", () => {
    // Same Swift-Optional contract as the other nullable-looking fields: nil
    // → absent key, not "siteName": null.
    const withNullSite = {
      title: "A paper",
      authors: "Alice",
      referenceType: "Journal Article",
      dateAdded: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      readingStatus: "unread",
      siteName: null,
      readCount: 0,
      customProperties: [],
    };
    expect(() => ReferenceDTO.parse(withNullSite)).toThrow();
  });

  it("accepts DatabaseViewDTO with groupBy explicitly null", () => {
    // AlwaysEncodedOptional forces null emission — schema must accept it.
    const view = {
      name: "Unread",
      icon: "📌",
      isDefault: false,
      displayOrder: 0,
      scope: { kind: "all" },
      columns: [],
      filters: [],
      sorts: [],
      groupBy: null,
      dateCreated: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
    };
    expect(() => DatabaseViewDTO.parse(view)).not.toThrow();
  });

  it("accepts CitationTextOutput", () => {
    const out = { style: "apa", inline: "(Alice, 2023)", bibliography: ["entry"] };
    expect(() => CitationTextOutput.parse(out)).not.toThrow();
  });

  it("accepts CitationDocxCCOutput with isShortTag omitted", () => {
    // CLI omits isShortTag when it's false, per RubienCLI.swift:205 comment.
    const out = { tag: "R1", text: "(Alice, 2023)", style: "apa" };
    expect(() => CitationDocxCCOutput.parse(out)).not.toThrow();
  });

  it("accepts PropertyDefinitionDTO with no options", () => {
    const def = {
      id: "p1",
      name: "My Property",
      type: "string",
      options: [],
      sortOrder: 0,
      isDefault: false,
      isVisible: true,
    };
    expect(() => PropertyDefinitionDTO.parse(def)).not.toThrow();
  });

  it("accepts a created-item CreateReferenceEnvelope with diagnostics omitted", () => {
    // Inline routes (`--title`) carry no diagnostics and no pdfDownload —
    // Swift-Optional contract: absent keys, never null.
    const envelope = {
      items: [
        {
          reference: {
            title: "A paper",
            authors: "Alice",
            referenceType: "Journal Article",
            dateAdded: "2026-04-24T10:00:00.000Z",
            dateModified: "2026-04-24T10:00:00.000Z",
            readingStatus: "unread",
            readCount: 0,
            customProperties: [],
          },
          status: "created",
          input: "A paper",
        },
      ],
      summary: { created: 1, existing: 0, queued: 0, failed: 0 },
    };
    expect(() => CreateReferenceEnvelope.parse(envelope)).not.toThrow();
  });

  it("accepts a failed item without a reference (synthetic zero-entries item)", () => {
    const envelope = {
      items: [
        { status: "failed", input: "bibtex", error: "No valid BibTeX entries found" },
      ],
      summary: { created: 0, existing: 0, queued: 0, failed: 1 },
    };
    expect(() => CreateReferenceEnvelope.parse(envelope)).not.toThrow();
  });

  it("accepts a queued item carrying intakeId + Zotero diagnostics", () => {
    const envelope = {
      items: [{ status: "queued", intakeId: 7, input: "/tmp/paper.pdf" }],
      summary: { created: 0, existing: 0, queued: 1, failed: 0 },
      diagnostics: { attached: 3, duplicatesSkipped: 1, missingPDFs: ["files/12/x.pdf"] },
    };
    expect(() => CreateReferenceEnvelope.parse(envelope)).not.toThrow();
  });

  it("rejects an out-of-enum item status", () => {
    const envelope = {
      items: [{ status: "merged", input: "x" }], // <-- not a Disposition
      summary: { created: 0, existing: 0, queued: 0, failed: 0 },
    };
    expect(() => CreateReferenceEnvelope.parse(envelope)).toThrow();
  });

  it("rejects an item missing `input` provenance", () => {
    // `input` is always present (§5.4) — dropping it would orphan multi-item
    // envelopes from their source entries.
    const envelope = {
      items: [{ status: "created" }],
      summary: { created: 1, existing: 0, queued: 0, failed: 0 },
    };
    expect(() => CreateReferenceEnvelope.parse(envelope)).toThrow();
  });

  it("accepts StyleDTO", () => {
    const s = {
      id: "apa",
      title: "APA 7th Edition",
      isBuiltin: true,
      citationKind: "in-text",
    };
    expect(() => StyleDTO.parse(s)).not.toThrow();
  });

  it("accepts ReadTextPdfOutput with a page-mode selection", () => {
    // Mirrors `read text --pages 1-3` on a PDF source. SelectionEcho's nil
    // optionals (matchedSections/unmatched) are absent, per the header comment.
    const out = {
      id: 7,
      source: "pdf",
      available: ["pdf", "web"],
      pageCount: 12,
      selection: { mode: "page", pages: "1-3", requested: ["1-3"] },
      pages: [{ index: 1, text: "Page one body", sectionPath: ["Introduction"] }],
      truncated: false,
      hasTextLayer: true,
    };
    expect(() => ReadTextPdfOutput.parse(out)).not.toThrow();
  });

  it("rejects ReadTextPdfOutput missing `available`", () => {
    // `available` is always emitted (the probe result); a drift that dropped it
    // would silently hide which sources are readable.
    const missingAvailable = {
      id: 7,
      source: "pdf",
      pageCount: 12,
      selection: { mode: "all" },
      pages: [],
      truncated: false,
      hasTextLayer: true,
    };
    expect(() => ReadTextPdfOutput.parse(missingAvailable)).toThrow();
  });

  it("rejects ReadTextPdfOutput with source `web`", () => {
    // The pdf mirror pins its discriminant literal — a web payload must fail it.
    const wrongSource = {
      id: 7,
      source: "web",
      available: ["pdf"],
      pageCount: 12,
      selection: { mode: "all" },
      pages: [],
      truncated: false,
      hasTextLayer: true,
    };
    expect(() => ReadTextPdfOutput.parse(wrongSource)).toThrow();
  });

  it("accepts ReadTextWebOutput with url/siteName present", () => {
    const out = {
      id: 9,
      source: "web",
      available: ["web"],
      url: "https://example.com/post",
      siteName: "example.com",
      contentFormat: "markdown",
      content: "# Title\n\nBody",
      contentLength: 13,
      start: 0,
      returnedChars: 13,
      truncated: false,
      annotationCount: 2,
    };
    expect(() => ReadTextWebOutput.parse(out)).not.toThrow();
  });

  it("accepts ReadTextWebOutput with url/siteName omitted", () => {
    // Swift-Optional contract: a web clip with no url/siteName omits the keys.
    const out = {
      id: 9,
      source: "web",
      available: ["web"],
      contentFormat: "html",
      content: "<p>fragment</p>",
      contentLength: 15,
      start: 0,
      returnedChars: 15,
      truncated: false,
      annotationCount: 0,
    };
    expect(() => ReadTextWebOutput.parse(out)).not.toThrow();
  });

  it("rejects ReadTextWebOutput with an out-of-enum contentFormat", () => {
    const badFormat = {
      id: 9,
      source: "web",
      available: ["web"],
      contentFormat: "text", // <-- only markdown | html are valid
      content: "body",
      contentLength: 4,
      start: 0,
      returnedChars: 4,
      truncated: false,
      annotationCount: 0,
    };
    expect(() => ReadTextWebOutput.parse(badFormat)).toThrow();
  });

  it("accepts a pdf-source ReadAnnotationItem", () => {
    // pdf items carry pageIndex + selectedText; web-only anchors are absent.
    const item = {
      source: "pdf",
      id: 3,
      type: "highlight",
      color: "#FFFF00",
      noteText: "important",
      dateCreated: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      pageIndex: 4,
      selectedText: "the quoted passage",
    };
    expect(() => ReadAnnotationItem.parse(item)).not.toThrow();
  });

  it("accepts a web-source ReadAnnotationItem with a TextQuoteSelector", () => {
    // web items carry prefix/anchor/suffix; noteText + pdf anchors are absent.
    const item = {
      source: "web",
      id: 5,
      type: "highlight",
      color: "#00FF00",
      dateCreated: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      anchorText: "the highlighted string",
      prefixText: "just ",
      suffixText: " here",
    };
    expect(() => ReadAnnotationItem.parse(item)).not.toThrow();
  });

  it("rejects a ReadAnnotationItem with an out-of-enum source", () => {
    const badSource = {
      source: "epub", // <-- only pdf | web are valid
      id: 5,
      type: "highlight",
      color: "#00FF00",
      dateCreated: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
    };
    expect(() => ReadAnnotationItem.parse(badSource)).toThrow();
  });

  it("rejects a ReadAnnotationItem missing dateModified", () => {
    // Both date fields are non-optional Date in Swift — always emitted.
    const missingDate = {
      source: "pdf",
      id: 3,
      type: "underline",
      color: "#FFFF00",
      dateCreated: "2026-04-24T10:00:00.000Z",
      pageIndex: 1,
    };
    expect(() => ReadAnnotationItem.parse(missingDate)).toThrow();
  });

  it("accepts GrepTextPdfOutput with page-grouped hits", () => {
    // Mirrors `grep <id> <query>` routed to a PDF source. Each page hit carries
    // snippetsTruncated (the per-page snippet cap) alongside its snippets.
    const out = {
      id: 7,
      source: "pdf",
      available: ["pdf", "web"],
      query: "transformer",
      isRegex: false,
      pageCount: 12,
      hasTextLayer: true,
      totalMatches: 5,
      totalMatchingPages: 2,
      truncated: false,
      pages: [
        {
          page: 3,
          sectionPath: ["Introduction"],
          matchCount: 3,
          snippetsTruncated: true,
          snippets: ["…the transformer architecture…"],
        },
      ],
    };
    expect(() => GrepTextPdfOutput.parse(out)).not.toThrow();
  });

  it("rejects GrepTextPdfOutput with a page hit missing snippetsTruncated", () => {
    // snippetsTruncated is non-optional (Bool) in PageSearchHit — always emitted.
    const out = {
      id: 7,
      source: "pdf",
      available: ["pdf"],
      query: "transformer",
      isRegex: false,
      pageCount: 12,
      hasTextLayer: true,
      totalMatches: 1,
      totalMatchingPages: 1,
      truncated: false,
      pages: [
        {
          page: 3,
          sectionPath: [],
          matchCount: 1,
          snippets: ["…hit…"], // <-- snippetsTruncated missing
        },
      ],
    };
    expect(() => GrepTextPdfOutput.parse(out)).toThrow();
  });

  it("rejects GrepTextPdfOutput with source `web`", () => {
    // The pdf mirror pins its discriminant literal — a web payload must fail it.
    const wrongSource = {
      id: 7,
      source: "web",
      available: ["pdf"],
      query: "x",
      isRegex: false,
      pageCount: 1,
      hasTextLayer: true,
      totalMatches: 0,
      totalMatchingPages: 0,
      truncated: false,
      pages: [],
    };
    expect(() => GrepTextPdfOutput.parse(wrongSource)).toThrow();
  });

  it("accepts GrepTextWebOutput with offset-anchored matches", () => {
    // Mirrors `grep <id> <query>` routed to a web source. `start` is a
    // character offset into the body — the same coordinate as read_text's start.
    const out = {
      id: 9,
      source: "web",
      available: ["web"],
      query: "distillation",
      isRegex: false,
      contentLength: 4200,
      totalMatches: 3,
      totalEntries: 3,
      truncated: false,
      matches: [
        { start: 0, matchCount: 1, snippet: "On-policy distillation…" },
        { start: 1840, matchCount: 2, snippet: "…the distillation loss…" },
      ],
    };
    expect(() => GrepTextWebOutput.parse(out)).not.toThrow();
  });

  it("rejects GrepTextWebOutput with a negative match start", () => {
    // `start` is a non-negative character offset — a negative value is invalid.
    const badStart = {
      id: 9,
      source: "web",
      available: ["web"],
      query: "x",
      isRegex: false,
      contentLength: 100,
      totalMatches: 1,
      totalEntries: 1,
      truncated: false,
      matches: [{ start: -1, matchCount: 1, snippet: "…hit…" }],
    };
    expect(() => GrepTextWebOutput.parse(badStart)).toThrow();
  });
});
