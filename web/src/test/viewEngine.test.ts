import { describe, expect, it } from "vitest";
import { defaultViews, emptyReference } from "../lib/model";
import { LibraryState } from "../lib/types";
import { applyView, materializeReferences } from "../lib/viewEngine";

describe("view engine", () => {
  it("filters, searches, and sorts local references", () => {
    const views = defaultViews();
    const view = {
      ...views[0],
      filters: [
        {
          target: { kind: "builtin" as const, value: "readingStatus" as const },
          op: "equals" as const,
          value: { kind: "text" as const, value: "Read" }
        }
      ],
      sorts: [{ target: { kind: "builtin" as const, value: "year" as const }, ascending: true }]
    };
    const state: LibraryState = {
      references: [
        emptyReference({ id: "r1", title: "Zeta", year: 2024, readingStatus: "Read" }),
        emptyReference({ id: "r2", title: "Alpha browser", year: 2022, readingStatus: "Read" }),
        emptyReference({ id: "r3", title: "Ignored browser", year: 2020, readingStatus: "Unread" })
      ],
      tags: [],
      referenceTags: [],
      properties: [],
      propertyValues: [],
      views: [view],
      annotations: [],
      files: [],
      pdfTextPages: []
    };

    const visible = applyView(materializeReferences(state), view, "browser");
    expect(visible.map((item) => item.reference.id)).toEqual(["r2"]);
  });

  it("filters tag arrays with contains-any semantics", () => {
    const [view] = defaultViews();
    const state: LibraryState = {
      references: [
        emptyReference({ id: "r1", title: "Tagged A" }),
        emptyReference({ id: "r2", title: "Tagged B" })
      ],
      tags: [
        { id: "t1", name: "Methods", color: "#007AFF", dateModified: "2026-01-01T00:00:00.000Z" },
        { id: "t2", name: "Review", color: "#34C759", dateModified: "2026-01-01T00:00:00.000Z" }
      ],
      referenceTags: [
        { id: "rt1", referenceId: "r1", tagId: "t1" },
        { id: "rt2", referenceId: "r2", tagId: "t2" }
      ],
      properties: [],
      propertyValues: [],
      views: [],
      annotations: [],
      files: [],
      pdfTextPages: []
    };

    const filtered = applyView(materializeReferences(state), {
      ...view,
      filters: [
        {
          target: { kind: "builtin", value: "tags" },
          op: "containsAnyOf",
          value: { kind: "selectKeys", value: ["Methods"] }
        }
      ]
    }, "");

    expect(filtered.map((item) => item.reference.id)).toEqual(["r1"]);
  });

  it("filters custom comma-separated multi-select values", () => {
    const [view] = defaultViews();
    const state: LibraryState = {
      references: [
        emptyReference({ id: "r1", title: "High priority" }),
        emptyReference({ id: "r2", title: "Low priority" })
      ],
      tags: [],
      referenceTags: [],
      properties: [],
      propertyValues: [
        {
          id: "pv1",
          referenceId: "r1",
          propertyId: "prop_priority",
          value: "High, Needs review",
          dateModified: "2026-01-01T00:00:00.000Z"
        },
        {
          id: "pv2",
          referenceId: "r2",
          propertyId: "prop_priority",
          value: "Low",
          dateModified: "2026-01-01T00:00:00.000Z"
        }
      ],
      views: [],
      annotations: [],
      files: [],
      pdfTextPages: []
    };

    const filtered = applyView(materializeReferences(state), {
      ...view,
      filters: [
        {
          target: { kind: "custom", value: "prop_priority" },
          op: "containsAllOf",
          value: { kind: "selectKeys", value: ["High", "Needs review"] }
        }
      ]
    }, "");

    expect(filtered.map((item) => item.reference.id)).toEqual(["r1"]);
  });

  it("compares date filters as dates", () => {
    const [view] = defaultViews();
    const state: LibraryState = {
      references: [
        emptyReference({ id: "r1", title: "Old", dateAdded: "2025-12-31T00:00:00.000Z" }),
        emptyReference({ id: "r2", title: "New", dateAdded: "2026-02-01T00:00:00.000Z" })
      ],
      tags: [],
      referenceTags: [],
      properties: [],
      propertyValues: [],
      views: [],
      annotations: [],
      files: [],
      pdfTextPages: []
    };

    const filtered = applyView(materializeReferences(state), {
      ...view,
      filters: [
        {
          target: { kind: "builtin", value: "dateAdded" },
          op: "greaterThan",
          value: { kind: "date", value: "2026-01-01" }
        }
      ]
    }, "");

    expect(filtered.map((item) => item.reference.id)).toEqual(["r2"]);
  });

  it("searches extracted PDF text", () => {
    const [view] = defaultViews();
    const state: LibraryState = {
      references: [
        emptyReference({ id: "r1", title: "Surface title" }),
        emptyReference({ id: "r2", title: "Other" })
      ],
      tags: [],
      referenceTags: [],
      properties: [],
      propertyValues: [],
      views: [],
      annotations: [],
      files: [],
      pdfTextPages: [
        {
          id: "pt1",
          referenceId: "r1",
          fileId: "f1",
          pageNumber: 1,
          text: "This PDF discusses cross-platform reference management.",
          extractedAt: "2026-01-01T00:00:00.000Z"
        }
      ]
    };

    const visible = applyView(materializeReferences(state), view, "cross-platform");
    expect(visible.map((item) => item.reference.id)).toEqual(["r1"]);
  });
});
