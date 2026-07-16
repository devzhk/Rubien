import "fake-indexeddb/auto";
import { Blob as NodeBlob } from "node:buffer";
import { afterEach, describe, expect, it } from "vitest";
import {
  attachPDF,
  base64ToBlob,
  blobToBase64,
  db,
  deleteReference,
  exportSnapshot,
  importSnapshot,
  loadLibraryState,
  markReferenceRead,
  putReference,
  replacePDFTextPages,
  setReferenceTags,
  upsertTag
} from "../lib/db";
import { emptyReference } from "../lib/model";

async function clearDatabase() {
  await Promise.all(db.tables.map((table) => table.clear()));
}

afterEach(async () => {
  await clearDatabase();
});

// jsdom's Blob/File lack arrayBuffer and fake-indexeddb's structuredClone
// mangles them, so binary can't be exercised through the DB here. Test the
// base64 codec directly (Node's Blob has arrayBuffer) — this is the piece that
// makes a JSON snapshot a complete PDF-carrying backup.
describe("base64 file codec", () => {
  it("encodes a blob to base64 and decodes it back to the same bytes", async () => {
    const bytes = new Uint8Array([0x25, 0x50, 0x44, 0x46]); // "%PDF"
    const encoded = await blobToBase64(new NodeBlob([bytes]) as unknown as Blob);
    expect(encoded).toBe("JVBERg==");
    const blob = base64ToBlob(encoded, "application/pdf");
    expect(blob.size).toBe(4);
    expect(blob.type).toBe("application/pdf");
  });
});

describe("snapshot export/import", () => {
  it("round-trips references, tags, and extracted PDF text through JSON", async () => {
    const ref = emptyReference({ id: "r1", title: "Has extracted text" });
    await putReference(ref);
    const tag = await upsertTag("methods", [], "#007AFF");
    await setReferenceTags(ref.id, [tag.id]);
    await replacePDFTextPages(ref.id, "f1", [{ pageNumber: 1, text: "hello world" }]);

    const snapshot = await exportSnapshot();
    expect(snapshot.pdfTextPages).toHaveLength(1);

    // The snapshot must survive JSON serialization and restore into a fresh DB.
    const roundTripped = JSON.parse(JSON.stringify(snapshot));
    await clearDatabase();
    await importSnapshot(roundTripped);

    const state = await loadLibraryState();
    expect(state.references.map((r) => r.id)).toContain("r1");
    expect(state.tags.map((t) => t.name)).toContain("methods");
    expect(state.referenceTags).toHaveLength(1);
    expect(state.pdfTextPages[0]?.text).toBe("hello world");
  });
});

describe("markReferenceRead", () => {
  it("increments the read count", async () => {
    const ref = emptyReference({ id: "r1", readCount: 2 });
    await putReference(ref);
    await markReferenceRead(ref);
    const [reloaded] = (await loadLibraryState()).references;
    expect(reloaded.readCount).toBe(3);
    expect(reloaded.lastReadAt).toBeTruthy();
  });

  it("does not produce NaN when readCount is missing", async () => {
    const { readCount: _omit, ...withoutCount } = emptyReference({ id: "r1" });
    await putReference(withoutCount as ReturnType<typeof emptyReference>);
    await markReferenceRead(withoutCount as ReturnType<typeof emptyReference>);
    const [reloaded] = (await loadLibraryState()).references;
    expect(reloaded.readCount).toBe(1);
  });
});

describe("deleteReference", () => {
  it("cascades to tags, files, and extracted text", async () => {
    const ref = emptyReference({ id: "r1", title: "To delete" });
    await putReference(ref);
    const tag = await upsertTag("methods", [], "#007AFF");
    await setReferenceTags(ref.id, [tag.id]);
    const stored = await attachPDF(ref.id, new File([new Uint8Array([1, 2, 3])], "a.pdf", { type: "application/pdf" }));
    await replacePDFTextPages(ref.id, stored.id, [{ pageNumber: 1, text: "text" }]);

    await deleteReference(ref.id);

    const state = await loadLibraryState();
    expect(state.references).toHaveLength(0);
    expect(state.referenceTags).toHaveLength(0);
    expect(state.files).toHaveLength(0);
    expect(state.pdfTextPages).toHaveLength(0);
  });
});
