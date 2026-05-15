import { describe, it, expect } from "vitest";
import {
  ReferenceDTO,
  PropertyDefinitionDTO,
  CitationTextOutput,
  CitationDocxCCOutput,
  DatabaseViewDTO,
  StyleDTO,
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

  it("accepts StyleDTO", () => {
    const s = {
      id: "apa",
      title: "APA 7th Edition",
      isBuiltin: true,
      citationKind: "in-text",
    };
    expect(() => StyleDTO.parse(s)).not.toThrow();
  });
});
