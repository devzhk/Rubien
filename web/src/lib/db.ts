import Dexie, { Table } from "dexie";
import {
  AnnotationRecord,
  DatabaseViewRecord,
  LibraryState,
  PDFTextPageRecord,
  PropertyDefinitionRecord,
  PropertyValueRecord,
  ReferenceRecord,
  ReferenceTagRecord,
  SerializedLibrarySnapshot,
  StoredFileRecord,
  TagRecord
} from "./types";
import { defaultProperties, defaultViews, id, nowISO } from "./model";

export class RubienWebDatabase extends Dexie {
  references!: Table<ReferenceRecord, string>;
  tags!: Table<TagRecord, string>;
  referenceTags!: Table<ReferenceTagRecord, string>;
  properties!: Table<PropertyDefinitionRecord, string>;
  propertyValues!: Table<PropertyValueRecord, string>;
  views!: Table<DatabaseViewRecord, string>;
  annotations!: Table<AnnotationRecord, string>;
  files!: Table<StoredFileRecord, string>;
  pdfTextPages!: Table<PDFTextPageRecord, string>;

  constructor() {
    super("rubien-web");
    this.version(1).stores({
      references:
        "&id, title, year, doi, url, referenceType, readingStatus, dateAdded, dateModified, lastReadAt, pdfFileId",
      tags: "&id, name, dateModified",
      referenceTags: "&id, referenceId, tagId, [referenceId+tagId]",
      properties: "&id, name, sortOrder, defaultFieldKey, dateModified",
      propertyValues: "&id, referenceId, propertyId, [referenceId+propertyId]",
      views: "&id, name, displayOrder, isDefault, dateModified",
      annotations: "&id, referenceId, kind, type, dateModified",
      files: "&id, referenceId, createdAt"
    });
    this.version(2).stores({
      references:
        "&id, title, year, doi, url, referenceType, readingStatus, dateAdded, dateModified, lastReadAt, pdfFileId",
      tags: "&id, name, dateModified",
      referenceTags: "&id, referenceId, tagId, [referenceId+tagId]",
      properties: "&id, name, sortOrder, defaultFieldKey, dateModified",
      propertyValues: "&id, referenceId, propertyId, [referenceId+propertyId]",
      views: "&id, name, displayOrder, isDefault, dateModified",
      annotations: "&id, referenceId, kind, type, dateModified",
      files: "&id, referenceId, createdAt",
      pdfTextPages: "&id, referenceId, fileId, [fileId+pageNumber]"
    });
  }
}

export const db = new RubienWebDatabase();

export async function initializeDatabase(): Promise<void> {
  const propertyCount = await db.properties.count();
  if (propertyCount === 0) {
    await db.properties.bulkPut(defaultProperties());
  }
  const viewCount = await db.views.count();
  if (viewCount === 0) {
    await db.views.bulkPut(defaultViews());
  }
}

export async function loadLibraryState(): Promise<LibraryState> {
  await initializeDatabase();
  const [references, tags, referenceTags, properties, propertyValues, views, annotations, files, pdfTextPages] =
    await Promise.all([
      db.references.toArray(),
      db.tags.toArray(),
      db.referenceTags.toArray(),
      db.properties.toArray(),
      db.propertyValues.toArray(),
      db.views.toArray(),
      db.annotations.toArray(),
      db.files.toArray(),
      db.pdfTextPages.toArray()
    ]);
  return {
    references,
    tags,
    referenceTags,
    properties,
    propertyValues,
    views,
    annotations,
    files,
    pdfTextPages
  };
}

export async function putReference(reference: ReferenceRecord): Promise<void> {
  await db.references.put({ ...reference, dateModified: nowISO() });
}

export async function addReferences(references: ReferenceRecord[]): Promise<void> {
  await db.references.bulkPut(references.map((reference) => ({ ...reference, dateModified: nowISO() })));
}

export async function deleteReference(referenceId: string): Promise<void> {
  await db.transaction("rw", [db.references, db.referenceTags, db.propertyValues, db.annotations, db.files, db.pdfTextPages], async () => {
    await db.references.delete(referenceId);
    await db.referenceTags.where("referenceId").equals(referenceId).delete();
    await db.propertyValues.where("referenceId").equals(referenceId).delete();
    await db.annotations.where("referenceId").equals(referenceId).delete();
    await db.pdfTextPages.where("referenceId").equals(referenceId).delete();
    await db.files.where("referenceId").equals(referenceId).delete();
  });
}

export async function upsertTag(name: string, usedColors: string[], colorForNew: string): Promise<TagRecord> {
  const trimmed = name.trim();
  const existing = await db.tags.where("name").equalsIgnoreCase(trimmed).first();
  if (existing) return existing;
  const tag: TagRecord = {
    id: id("tag"),
    name: trimmed,
    color: colorForNew || usedColors[0] || "#007AFF",
    dateModified: nowISO()
  };
  await db.tags.put(tag);
  return tag;
}

export async function setReferenceTags(referenceId: string, tagIds: string[]): Promise<void> {
  const unique = [...new Set(tagIds)];
  await db.transaction("rw", db.references, db.referenceTags, async () => {
    await db.referenceTags.where("referenceId").equals(referenceId).delete();
    await db.referenceTags.bulkPut(
      unique.map((tagId) => ({
        id: id("rtag"),
        referenceId,
        tagId
      }))
    );
    const reference = await db.references.get(referenceId);
    if (reference) await db.references.put({ ...reference, dateModified: nowISO() });
  });
}

export async function putPropertyValue(referenceId: string, propertyId: string, value: string): Promise<void> {
  const existing = await db.propertyValues
    .where("[referenceId+propertyId]")
    .equals([referenceId, propertyId])
    .first();
  const dateModified = nowISO();
  if (value === "") {
    if (existing) await db.propertyValues.delete(existing.id);
    return;
  }
  await db.propertyValues.put({
    id: existing?.id ?? id("pval"),
    referenceId,
    propertyId,
    value,
    dateModified
  });
}

export async function putView(view: DatabaseViewRecord): Promise<void> {
  await db.views.put({ ...view, dateModified: nowISO() });
}

export async function putProperty(property: PropertyDefinitionRecord): Promise<void> {
  await db.properties.put({ ...property, dateModified: nowISO() });
}

export async function putAnnotation(annotation: AnnotationRecord): Promise<void> {
  await db.annotations.put({ ...annotation, dateModified: nowISO() });
}

export async function deleteAnnotation(annotationId: string): Promise<void> {
  await db.annotations.delete(annotationId);
}

export async function attachPDF(referenceId: string, file: File): Promise<StoredFileRecord> {
  const stored: StoredFileRecord = {
    id: id("file"),
    referenceId,
    name: file.name,
    type: file.type || "application/pdf",
    size: file.size,
    blob: file,
    createdAt: nowISO()
  };
  await db.transaction("rw", db.references, db.files, db.pdfTextPages, async () => {
    await db.files.where("referenceId").equals(referenceId).delete();
    await db.pdfTextPages.where("referenceId").equals(referenceId).delete();
    await db.files.put(stored);
    const reference = await db.references.get(referenceId);
    if (reference) {
      await db.references.put({
        ...reference,
        pdfFileId: stored.id,
        dateModified: nowISO()
      });
    }
  });
  return stored;
}

export async function getPDFTextPages(fileId: string): Promise<PDFTextPageRecord[]> {
  return db.pdfTextPages.where("fileId").equals(fileId).sortBy("pageNumber");
}

export async function replacePDFTextPages(
  referenceId: string,
  fileId: string,
  pages: Array<{ pageNumber: number; text: string }>
): Promise<void> {
  const extractedAt = nowISO();
  await db.transaction("rw", db.pdfTextPages, async () => {
    await db.pdfTextPages.where("fileId").equals(fileId).delete();
    await db.pdfTextPages.bulkPut(
      pages.map((page) => ({
        id: id("pdftext"),
        referenceId,
        fileId,
        pageNumber: page.pageNumber,
        text: page.text,
        extractedAt
      }))
    );
  });
}

export async function markReferenceRead(reference: ReferenceRecord): Promise<void> {
  await db.references.put({
    ...reference,
    lastReadAt: nowISO(),
    // Imported/foreign records may lack readCount; guard against NaN.
    readCount: (reference.readCount ?? 0) + 1,
    dateModified: nowISO()
  });
}

export async function exportSnapshot(): Promise<SerializedLibrarySnapshot> {
  const state = await loadLibraryState();
  const files = await Promise.all(
    state.files.map(async (file) => ({
      id: file.id,
      referenceId: file.referenceId,
      name: file.name,
      type: file.type,
      size: file.size,
      dataBase64: await blobToBase64(file.blob),
      createdAt: file.createdAt
    }))
  );
  return {
    references: state.references,
    tags: state.tags,
    referenceTags: state.referenceTags,
    properties: state.properties,
    propertyValues: state.propertyValues,
    views: state.views,
    annotations: state.annotations,
    files,
    pdfTextPages: state.pdfTextPages
  };
}

export async function importSnapshot(snapshot: SerializedLibrarySnapshot): Promise<void> {
  const files: StoredFileRecord[] = (snapshot.files ?? []).map((file) => ({
    id: file.id,
    referenceId: file.referenceId,
    name: file.name,
    type: file.type,
    size: file.size,
    blob: base64ToBlob(file.dataBase64, file.type),
    createdAt: file.createdAt
  }));
  await db.transaction(
    "rw",
    [db.references, db.tags, db.referenceTags, db.properties, db.propertyValues, db.views, db.annotations, db.files, db.pdfTextPages],
    async () => {
      await db.references.bulkPut(snapshot.references ?? []);
      await db.tags.bulkPut(snapshot.tags ?? []);
      await db.referenceTags.bulkPut(snapshot.referenceTags ?? []);
      await db.properties.bulkPut(snapshot.properties ?? []);
      await db.propertyValues.bulkPut(snapshot.propertyValues ?? []);
      await db.views.bulkPut(snapshot.views ?? []);
      await db.annotations.bulkPut(snapshot.annotations ?? []);
      if (files.length) await db.files.bulkPut(files);
      if (snapshot.pdfTextPages?.length) await db.pdfTextPages.bulkPut(snapshot.pdfTextPages);
    }
  );
}

export async function blobToBase64(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function base64ToBlob(data: string, type: string): Blob {
  const binary = atob(data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return new Blob([bytes], { type });
}
