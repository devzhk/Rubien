import { z } from "zod";

// -----------------------------------------------------------------------------
// Zod schemas mirroring the DTO structs in Sources/RubienCLI/RubienCLI.swift.
//
// Convention (load-bearing — a drift here silently breaks tool parsing):
//   - Swift `let x: T?` (regular Optional) → `.optional()` in zod.
//     Swift's JSONEncoder *omits* nil-valued optionals from output entirely,
//     so `.nullable()` would fail to parse real CLI output.
//   - `AlwaysEncodedOptional<T>` (e.g. DatabaseViewDTO.groupBy) → `.nullable()`.
//     That wrapper forces an explicit `null` emission when nil.
// -----------------------------------------------------------------------------

const isoDateString = z
  .string()
  .describe("ISO-8601 timestamp with millisecond precision, e.g. 2026-04-24T12:00:00.000Z");

export const CustomPropertyValueDTO = z.object({
  propertyId: z.string(),
  name: z.string(),
  type: z.string(),
  value: z.string(),
});
export type CustomPropertyValueDTO = z.infer<typeof CustomPropertyValueDTO>;

export const ReferenceDTO = z.object({
  id: z.number().int().optional(),
  title: z.string(),
  authors: z.string(),
  year: z.number().int().optional(),
  journal: z.string().optional(),
  volume: z.string().optional(),
  issue: z.string().optional(),
  pages: z.string().optional(),
  doi: z.string().optional(),
  url: z.string().optional(),
  abstract: z.string().optional(),
  referenceType: z.string(),
  dateAdded: isoDateString,
  dateModified: isoDateString,
  pdfPath: z.string().optional(),
  notes: z.string().optional(),
  isbn: z.string().optional(),
  issn: z.string().optional(),
  publisher: z.string().optional(),
  language: z.string().optional(),
  edition: z.string().optional(),
  readingStatus: z.string(),
  // Reader activity (v4). `lastReadAt` is a Swift `Date?` and is omitted from
  // CLI output when the reference has never been opened — `.optional()`, not
  // `.nullable()` (see header comment). `readCount` is non-optional and
  // always present, defaulting to 0.
  lastReadAt: isoDateString.optional(),
  readCount: z.number().int(),
  customProperties: z.array(CustomPropertyValueDTO),
});
export type ReferenceDTO = z.infer<typeof ReferenceDTO>;

/// Mirror of `PropertyOptionDTO` in RubienCLI.swift. `value` is the canonical
/// identity (option string for custom selects; stringified tag id for the
/// built-in Tags property). `label` is the display text — equal to `value`
/// for custom options, and the Tag's name for Tags-routed options.
export const PropertyOptionDTO = z.object({
  value: z.string(),
  label: z.string(),
  color: z.string(),
});
export type PropertyOptionDTO = z.infer<typeof PropertyOptionDTO>;

export const PropertyDefinitionDTO = z.object({
  id: z.string(),
  name: z.string(),
  type: z.string(),
  options: z.array(PropertyOptionDTO),
  sortOrder: z.number().int(),
  isDefault: z.boolean(),
  defaultFieldKey: z.string().optional(),
  isVisible: z.boolean(),
});
export type PropertyDefinitionDTO = z.infer<typeof PropertyDefinitionDTO>;

// PDF-download status DTO emitted by `add --identifier --download-pdf` and by
// `pdf download <id>`. Mirrors PDFDownloadStatusDTO in RubienCLI.swift.
// `action` is the raw value of PDFDownloadAction (downloaded | already-attached
// | already-pending | skipped). All fields except `ok` use plain `Optional` in
// Swift → key omitted when nil → `.optional()` here.
export const PDFDownloadStatusDTO = z.object({
  ok: z.boolean(),
  action: z.string().optional(),
  filename: z.string().optional(),
  error: z.string().optional(),
});
export type PDFDownloadStatusDTO = z.infer<typeof PDFDownloadStatusDTO>;

// Envelope returned by `add` (single object) or `add --bibtex` (array of these).
// `status` mirrors AppDatabase.ReferenceSaveResult.
// `pdfDownload` is an AlwaysEncodedOptional in Swift, so it's always present
// in the JSON — explicit `null` when --download-pdf wasn't set.
export const AddStatusOutput = z.object({
  reference: ReferenceDTO,
  status: z.enum(["created", "existing"]),
  pdfDownload: PDFDownloadStatusDTO.nullable(),
});
export type AddStatusOutput = z.infer<typeof AddStatusOutput>;

// TagDTO retired alongside the rubien_tags_* MCP tool family. Tag rows now
// surface as inline options on the built-in Tags PropertyDefinition (see
// PropertyOptionDTO above): `value` is the stringified tag id, `label` is
// the tag name, `color` is the tag color.

// Citation outputs (three formats: text, bibliography, docx-cc).
export const CitationTextOutput = z.object({
  style: z.string(),
  inline: z.string(),
  bibliography: z.array(z.string()),
});

export const CitationBibliographyOutput = z.object({
  style: z.string(),
  entries: z.array(z.string()),
});

export const CitationDocxCCOutput = z.object({
  tag: z.string(),
  text: z.string(),
  style: z.string(),
  isShortTag: z.boolean().optional(),
  fallbackPayload: z.string().optional(),
});

// View DTO: groupBy uses AlwaysEncodedOptional → nullable in JSON.
export const ViewFilter = z.object({}).passthrough(); // structural detail varies; accept any shape
export const ViewSort = z.object({}).passthrough();
export const ColumnConfig = z.object({}).passthrough();
export const GroupConfig = z.object({}).passthrough();
export const ViewScope = z.object({}).passthrough();

export const DatabaseViewDTO = z.object({
  id: z.number().int().optional(),
  name: z.string(),
  icon: z.string(),
  isDefault: z.boolean(),
  displayOrder: z.number().int(),
  scope: ViewScope,
  columns: z.array(ColumnConfig),
  filters: z.array(ViewFilter),
  sorts: z.array(ViewSort),
  groupBy: GroupConfig.nullable(), // AlwaysEncodedOptional → explicit null
  dateCreated: isoDateString,
  dateModified: isoDateString,
});
export type DatabaseViewDTO = z.infer<typeof DatabaseViewDTO>;

export const AnnotationDTO = z.object({
  id: z.number().int(),
  type: z.string(),
  color: z.string().optional(),
  pageIndex: z.number().int().optional(),
  selectedText: z.string().optional(),
  noteText: z.string().optional(),
});

export const StyleDTO = z.object({
  id: z.string(),
  title: z.string(),
  isBuiltin: z.boolean(),
  citationKind: z.string(),
});

export const SyncStatusDTO = z
  .object({
    enabled: z.boolean(),
    containerIdentifier: z.string().optional(),
    entitlementPresent: z.boolean(),
    iCloudAccountAvailable: z.boolean(),
    appLockHeld: z.boolean().optional(),
    baselineState: z.string(),
    dirtyByEntityType: z.record(z.number()).optional(),
    tombstoneCount: z.number().optional(),
    syncEngineState: z.unknown().optional(),
    schemaVersion: z.number().int().optional(),
  })
  .passthrough(); // sync status is relatively fluid; keep forward-compat

export const DeleteResultDTO = z.object({ deleted: z.string() });
export const ImportResultDTO = z
  .object({ imported: z.number().int(), file: z.string() })
  .passthrough();

export const CliErrorDTO = z.object({ error: z.string() });
