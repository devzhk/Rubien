export const referenceTypes = [
  "Journal Article",
  "Conference Paper",
  "Book",
  "Thesis",
  "Web Page",
  "Markdown",
  "Other"
] as const;

export type ReferenceType = (typeof referenceTypes)[number];

export const readingStatuses = ["Unread", "Skimmed", "Read"] as const;
export type ReadingStatus = (typeof readingStatuses)[number] | string;

export interface AuthorName {
  given: string;
  family: string;
}

export type MetadataSource =
  | "manual"
  | "doi"
  | "arxiv"
  | "isbn"
  | "openalex"
  | "bibtex"
  | "ris"
  | "json"
  | "web";

export type VerificationStatus = "legacy" | "seedOnly" | "candidate" | "verified";

export interface ReferenceRecord {
  id: string;
  title: string;
  authors: AuthorName[];
  year?: number;
  journal?: string;
  volume?: string;
  issue?: string;
  pages?: string;
  doi?: string;
  url?: string;
  abstract?: string;
  dateAdded: string;
  dateModified: string;
  notes?: string;
  webContent?: string;
  webContentFormat?: "markdown" | "html" | "text";
  siteName?: string;
  favicon?: string;
  referenceType: ReferenceType;
  metadataSource?: MetadataSource;
  verificationStatus: VerificationStatus;
  readingStatus: ReadingStatus;
  lastReadAt?: string;
  readCount: number;
  publisher?: string;
  publisherPlace?: string;
  edition?: string;
  editors?: AuthorName[];
  isbn?: string;
  issn?: string;
  accessedDate?: string;
  issuedMonth?: number;
  issuedDay?: number;
  translators?: AuthorName[];
  eventTitle?: string;
  eventPlace?: string;
  genre?: string;
  institution?: string;
  number?: string;
  collectionTitle?: string;
  numberOfPages?: string;
  language?: string;
  pmid?: string;
  pmcid?: string;
  pdfFileId?: string;
}

export interface TagRecord {
  id: string;
  name: string;
  color: string;
  dateModified: string;
}

export interface ReferenceTagRecord {
  id: string;
  referenceId: string;
  tagId: string;
}

export type PropertyType =
  | "string"
  | "url"
  | "number"
  | "singleSelect"
  | "multiSelect"
  | "date"
  | "checkbox";

export interface SelectOption {
  value: string;
  color: string;
}

export interface PropertyDefinitionRecord {
  id: string;
  name: string;
  type: PropertyType;
  options: SelectOption[];
  sortOrder: number;
  isDefault: boolean;
  defaultFieldKey?: "tags" | "readingStatus" | "referenceType";
  isVisible: boolean;
  dateModified: string;
}

export interface PropertyValueRecord {
  id: string;
  referenceId: string;
  propertyId: string;
  value: string;
  dateModified: string;
}

export type ColumnIdentifier =
  | "title"
  | "authors"
  | "year"
  | "journal"
  | "referenceType"
  | "tags"
  | "readingStatus"
  | "dateAdded"
  | "dateModified"
  | "doi"
  | "publisher"
  | "volume"
  | "issue"
  | "pages"
  | "pdfAttached"
  | "lastReadAt"
  | "readCount";

export interface ColumnConfig {
  columnId: ColumnIdentifier;
  width?: number;
  isVisible: boolean;
  displayOrder: number;
}

export type FieldTarget =
  | { kind: "builtin"; value: ColumnIdentifier }
  | { kind: "custom"; value: string };

export type FilterOperator =
  | "equals"
  | "notEquals"
  | "contains"
  | "notContains"
  | "startsWith"
  | "endsWith"
  | "greaterThan"
  | "lessThan"
  | "greaterOrEqual"
  | "lessOrEqual"
  | "isAnyOf"
  | "isNoneOf"
  | "containsAnyOf"
  | "containsNoneOf"
  | "containsAllOf"
  | "isChecked"
  | "isUnchecked"
  | "isEmpty"
  | "isNotEmpty";

export type FilterValue =
  | { kind: "text"; value: string }
  | { kind: "number"; value: number }
  | { kind: "date"; value: string }
  | { kind: "selectKeys"; value: string[] }
  | { kind: "bool"; value: boolean }
  | { kind: "none" };

export interface ViewFilter {
  target: FieldTarget;
  op: FilterOperator;
  value: FilterValue;
}

export interface ViewSort {
  target: FieldTarget;
  ascending: boolean;
}

export interface GroupConfig {
  target: FieldTarget;
  dateBin?: "week" | "month" | "year";
  customOrder?: string[];
  collapsed: string[];
  showEmpty: boolean;
}

export interface DatabaseViewRecord {
  id: string;
  name: string;
  icon: string;
  scope: { kind: "all" } | { kind: "tag"; tagId: string };
  columns: ColumnConfig[];
  filters: ViewFilter[];
  sorts: ViewSort[];
  groupBy?: GroupConfig;
  columnWraps: string[];
  isDefault: boolean;
  displayOrder: number;
  dateCreated: string;
  dateModified: string;
}

export type AnnotationType = "highlight" | "underline" | "note";
export type AnnotationKind = "pdf" | "web";

export interface AnnotationRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface AnnotationRecord {
  id: string;
  referenceId: string;
  kind: AnnotationKind;
  type: AnnotationType;
  selectedText?: string;
  noteText?: string;
  color: string;
  pageIndex?: number;
  rects?: AnnotationRect[];
  anchorText?: string;
  prefixText?: string;
  suffixText?: string;
  dateCreated: string;
  dateModified: string;
}

export interface StoredFileRecord {
  id: string;
  referenceId: string;
  name: string;
  type: string;
  size: number;
  blob: Blob;
  createdAt: string;
}

export interface PDFTextPageRecord {
  id: string;
  referenceId: string;
  fileId: string;
  pageNumber: number;
  text: string;
  extractedAt: string;
}

export interface LibrarySnapshot {
  references: ReferenceRecord[];
  tags: TagRecord[];
  referenceTags: ReferenceTagRecord[];
  properties: PropertyDefinitionRecord[];
  propertyValues: PropertyValueRecord[];
  views: DatabaseViewRecord[];
  annotations: AnnotationRecord[];
}

// A file record whose Blob is base64-encoded so it survives JSON serialization.
// PDFs are opaque binary; without this the JSON "backup" silently omits them.
export interface SerializedFileRecord {
  id: string;
  referenceId: string;
  name: string;
  type: string;
  size: number;
  dataBase64: string;
  createdAt: string;
}

// The on-disk JSON export shape: the metadata snapshot plus attached PDFs and
// their extracted text, so a snapshot is a complete, portable backup. `files`
// and `pdfTextPages` are optional for forward/backward compatibility with
// older metadata-only exports.
export interface SerializedLibrarySnapshot extends LibrarySnapshot {
  files?: SerializedFileRecord[];
  pdfTextPages?: PDFTextPageRecord[];
}

export interface LibraryState extends LibrarySnapshot {
  files: StoredFileRecord[];
  pdfTextPages: PDFTextPageRecord[];
}

export interface MaterializedReference {
  reference: ReferenceRecord;
  tags: TagRecord[];
  propertyValues: Record<string, string>;
  annotations: AnnotationRecord[];
  pdfFile?: StoredFileRecord;
  pdfTextPages: PDFTextPageRecord[];
}
