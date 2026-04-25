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
    const minimal = {
      title: "A paper",
      authors: "Alice; Bob",
      referenceType: "Journal Article",
      dateAdded: "2026-04-24T10:00:00.000Z",
      dateModified: "2026-04-24T10:00:00.000Z",
      readingStatus: "unread",
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
      customProperties: [],
    };
    expect(() => ReferenceDTO.parse(withNull)).toThrow();
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
