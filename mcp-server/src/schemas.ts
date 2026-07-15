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
  siteName: z.string().optional(),
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

// PDF-download status DTO emitted by the create-reference resolver route's
// PDF fetch and by `pdf download <id>`. Mirrors PDFDownloadStatusDTO in
// RubienCLI.swift. `action` is the raw value of PDFDownloadAction (downloaded
// | replaced | already-attached | already-pending | skipped). All fields
// except `ok` use plain `Optional` in Swift → key omitted when nil →
// `.optional()` here.
export const PDFDownloadStatusDTO = z.object({
  ok: z.boolean(),
  action: z.string().optional(),
  filename: z.string().optional(),
  error: z.string().optional(),
});
export type PDFDownloadStatusDTO = z.infer<typeof PDFDownloadStatusDTO>;

// Unified create-reference envelope (spec §5.4) — one shape for every route
// (`add --source` / `--bibtex` / `--title`). Swift-Optional contract as
// everywhere: absent keys, never null. `diagnostics` appears only when the
// route produces it; `pdfDownload` only when a fetch was attempted.
export const CreateReferenceItem = z.object({
  reference: ReferenceDTO.optional(),
  status: z.enum(["created", "existing", "queued", "failed"]),
  intakeId: z.number().int().optional(),
  input: z.string(),
  pdfDownload: PDFDownloadStatusDTO.optional(),
  error: z.string().optional(),
});
export type CreateReferenceItem = z.infer<typeof CreateReferenceItem>;

export const CreateReferenceEnvelope = z.object({
  items: z.array(CreateReferenceItem),
  summary: z.object({
    created: z.number().int(),
    existing: z.number().int(),
    queued: z.number().int(),
    failed: z.number().int(),
  }),
  diagnostics: z
    .object({
      file: z.string().optional(),
      property: z.string().optional(),
      value: z.string().optional(),
      attached: z.number().int().optional(),
      duplicatesSkipped: z.number().int().optional(),
      missingPDFs: z.array(z.string()).optional(),
    })
    .optional(),
});
export type CreateReferenceEnvelope = z.infer<typeof CreateReferenceEnvelope>;

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

// Unified read-tool output mirrors (RubienCLI `read text` / `read annotations`).
// Superseded the permissive AnnotationDTO, which was retired alongside the
// kind-specific rubien_web_* / rubien_annotations_list tools.
export const ReadTextPdfOutput = z.object({
  id: z.number().int(),
  source: z.literal("pdf"),
  available: z.array(z.enum(["pdf", "web"])),
  pageCount: z.number().int(),
  selection: z.object({
    mode: z.string(),
    pages: z.string().optional(),
    requested: z.array(z.string()).optional(),
    matchedSections: z.array(z.string()).optional(),
    unmatched: z.array(z.string()).optional(),
  }),
  pages: z.array(z.object({
    index: z.number().int(),
    text: z.string(),
    sectionPath: z.array(z.string()),
  })),
  truncated: z.boolean(),
  hasTextLayer: z.boolean(),
});
export type ReadTextPdfOutput = z.infer<typeof ReadTextPdfOutput>;

export const ReadTextWebOutput = z.object({
  id: z.number().int(),
  source: z.literal("web"),
  available: z.array(z.enum(["pdf", "web"])),
  url: z.string().optional(),
  siteName: z.string().optional(),
  contentFormat: z.enum(["markdown", "html"]),
  content: z.string(),
  contentLength: z.number().int(),
  start: z.number().int(),
  returnedChars: z.number().int(),
  truncated: z.boolean(),
  annotationCount: z.number().int(),
});
export type ReadTextWebOutput = z.infer<typeof ReadTextWebOutput>;

export const ReadAnnotationItem = z.object({
  source: z.enum(["pdf", "web"]),
  id: z.number().int(),
  type: z.string(),
  color: z.string(),
  noteText: z.string().optional(),
  dateCreated: isoDateString,
  dateModified: isoDateString,
  pageIndex: z.number().int().optional(),
  selectedText: z.string().optional(),
  anchorText: z.string().optional(),
  prefixText: z.string().optional(),
  suffixText: z.string().optional(),
});
export type ReadAnnotationItem = z.infer<typeof ReadAnnotationItem>;

// Unified grep-tool output mirrors (RubienCLI `grep <id> <query>`). PDF hits are
// page-grouped (PageSearchHit); web hits carry character offsets (GrepWebMatch).
export const GrepTextPdfOutput = z.object({
  id: z.number().int(),
  source: z.literal("pdf"),
  available: z.array(z.enum(["pdf", "web"])),
  query: z.string(),
  isRegex: z.boolean(),
  pageCount: z.number().int(),
  hasTextLayer: z.boolean(),
  totalMatches: z.number().int(),
  totalMatchingPages: z.number().int(),
  truncated: z.boolean(),
  pages: z.array(z.object({
    page: z.number().int(),
    sectionPath: z.array(z.string()),
    matchCount: z.number().int(),
    snippetsTruncated: z.boolean(),
    snippets: z.array(z.string()),
  })),
});
export type GrepTextPdfOutput = z.infer<typeof GrepTextPdfOutput>;

export const GrepTextWebOutput = z.object({
  id: z.number().int(),
  source: z.literal("web"),
  available: z.array(z.enum(["pdf", "web"])),
  query: z.string(),
  isRegex: z.boolean(),
  contentLength: z.number().int(),
  totalMatches: z.number().int(),
  totalEntries: z.number().int(),
  truncated: z.boolean(),
  matches: z.array(z.object({
    start: z.number().int().nonnegative(),
    matchCount: z.number().int(),
    snippet: z.string(),
  })),
});
export type GrepTextWebOutput = z.infer<typeof GrepTextWebOutput>;

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
// (ImportResultDTO removed with the `import` subcommand; CliErrorDTO removed
// with the verbatim-stderr change — errors are now raw envelope text, which
// may be a structured `{error, ids, names}` / `{items, summary}` shape, not a
// plain `{error}` object.)
