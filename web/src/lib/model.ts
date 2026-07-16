import {
  AuthorName,
  ColumnConfig,
  DatabaseViewRecord,
  PropertyType,
  PropertyDefinitionRecord,
  ReferenceRecord,
  SelectOption,
  TagRecord,
  referenceTypes,
  readingStatuses
} from "./types";

export const colorPalette = [
  "#007AFF",
  "#34C759",
  "#FF9500",
  "#FF3B30",
  "#AF52DE",
  "#5AC8FA",
  "#FF2D55",
  "#FFCC00",
  "#00C7BE",
  "#8E8E93",
  "#30B0C7",
  "#A2845E",
  "#FF6482",
  "#64D2FF",
  "#BF5AF2"
];

export const defaultColumns: ColumnConfig[] = [
  { columnId: "title", isVisible: true, displayOrder: 0 },
  { columnId: "authors", isVisible: true, displayOrder: 1 },
  { columnId: "year", isVisible: true, displayOrder: 2 },
  { columnId: "journal", isVisible: true, displayOrder: 3 },
  { columnId: "referenceType", isVisible: true, displayOrder: 4 },
  { columnId: "tags", isVisible: true, displayOrder: 5 },
  { columnId: "readingStatus", isVisible: true, displayOrder: 6 },
  { columnId: "dateAdded", isVisible: true, displayOrder: 7 },
  { columnId: "dateModified", isVisible: false, displayOrder: 8 },
  { columnId: "doi", isVisible: false, displayOrder: 9 },
  { columnId: "publisher", isVisible: false, displayOrder: 10 },
  { columnId: "volume", isVisible: false, displayOrder: 11 },
  { columnId: "issue", isVisible: false, displayOrder: 12 },
  { columnId: "pages", isVisible: false, displayOrder: 13 },
  { columnId: "pdfAttached", isVisible: false, displayOrder: 14 },
  { columnId: "lastReadAt", isVisible: false, displayOrder: 15 },
  { columnId: "readCount", isVisible: false, displayOrder: 16 }
];

export function nowISO(): string {
  return new Date().toISOString();
}

export function id(prefix: string): string {
  return `${prefix}_${crypto.randomUUID()}`;
}

export function nextUnusedColor(used: string[]): string {
  return colorPalette.find((color) => !used.includes(color)) ?? colorPalette[0];
}

export function normalizeSpace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

export function stripBibTeXBraces(value: string): string {
  // No braces: still undo the backslash-escaping of LaTeX specials that
  // `escapeBibTeX` applies on export, so an export→import round-trip is
  // lossless. (The brace-processing path below already unescapes `\x`.)
  if (!value.includes("{")) return value.replace(/\\([&%#$_])/g, "$1").trim();
  let result = "";
  let escaped = false;
  for (const char of value) {
    if (escaped) {
      result += char;
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char !== "{" && char !== "}") result += char;
  }
  return result.trim();
}

function splitRespectingBraces(text: string, separator: string): string[] {
  if (!text.includes("{")) return text.split(separator);
  const parts: string[] = [];
  let current = "";
  let depth = 0;
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (char === "\\" && i + 1 < text.length) {
      current += char + text[i + 1];
      i += 1;
      continue;
    }
    if (char === "{") {
      depth += 1;
      current += char;
      continue;
    }
    if (char === "}") {
      depth = Math.max(0, depth - 1);
      current += char;
      continue;
    }
    if (depth === 0 && text.startsWith(separator, i)) {
      parts.push(current);
      current = "";
      i += separator.length - 1;
      continue;
    }
    current += char;
  }
  parts.push(current);
  return parts;
}

export function parseAuthor(text: string): AuthorName {
  const trimmed = normalizeSpace(text);
  const commaParts = splitRespectingBraces(trimmed, ",");
  if (commaParts.length >= 2) {
    return {
      family: stripBibTeXBraces(commaParts[0]),
      given: stripBibTeXBraces(commaParts.slice(1).join(","))
    };
  }
  const parts = splitRespectingBraces(trimmed, " ").filter(Boolean);
  if (parts.length >= 2) {
    return {
      given: stripBibTeXBraces(parts.slice(0, -1).join(" ")),
      family: stripBibTeXBraces(parts[parts.length - 1])
    };
  }
  return { given: "", family: stripBibTeXBraces(trimmed) };
}

export function parseAuthors(text: string): AuthorName[] {
  const trimmed = text.trim();
  if (!trimmed) return [];
  const semicolon = splitRespectingBraces(trimmed, ";");
  const lowerAnd = splitRespectingBraces(trimmed.toLowerCase(), " and ");
  let parts: string[];
  if (semicolon.length > 1) {
    parts = semicolon;
  } else if (lowerAnd.length > 1) {
    parts = splitRespectingBraces(trimmed, " and ");
  } else {
    const comma = splitRespectingBraces(trimmed, ",").map((part) => part.trim()).filter(Boolean);
    const pairLike =
      comma.length === 2 ||
      (comma.length > 2 && comma.length % 2 === 0 && comma.every((part, index) => index % 2 === 1 || !part.includes(" ")));
    if (pairLike) {
      const names: AuthorName[] = [];
      for (let i = 0; i < comma.length; i += 2) {
        names.push({ family: stripBibTeXBraces(comma[i]), given: stripBibTeXBraces(comma[i + 1] ?? "") });
      }
      return names.filter((name) => name.family);
    }
    parts = comma;
  }
  return parts.map(parseAuthor).filter((name) => name.family);
}

export function authorDisplay(authors: AuthorName[]): string {
  return authors.map((author) => (author.given ? `${author.given} ${author.family}` : author.family)).join(", ");
}

export function authorShort(author: AuthorName): string {
  return author.family || author.given || "Unknown";
}

export function defaultProperties(): PropertyDefinitionRecord[] {
  const dateModified = nowISO();
  const statusOptions: SelectOption[] = readingStatuses.map((value, index) => ({
    value,
    color: colorPalette[index]
  }));
  const typeOptions: SelectOption[] = referenceTypes.map((value, index) => ({
    value,
    color: colorPalette[(index + 4) % colorPalette.length]
  }));
  return [
    {
      id: "prop_tags",
      name: "Tags",
      type: "multiSelect",
      options: [],
      sortOrder: 0,
      isDefault: true,
      defaultFieldKey: "tags",
      isVisible: true,
      dateModified
    },
    {
      id: "prop_status",
      name: "Status",
      type: "singleSelect",
      options: statusOptions,
      sortOrder: 1,
      isDefault: true,
      defaultFieldKey: "readingStatus",
      isVisible: true,
      dateModified
    },
    {
      id: "prop_type",
      name: "Type",
      type: "singleSelect",
      options: typeOptions,
      sortOrder: 2,
      isDefault: true,
      defaultFieldKey: "referenceType",
      isVisible: true,
      dateModified
    }
  ];
}

export function customPropertyFromInput(
  name: string,
  type: PropertyType,
  optionsText: string,
  sortOrder: number
): PropertyDefinitionRecord {
  const options = optionsText
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value, index) => ({
      value,
      color: colorPalette[index % colorPalette.length]
    }));
  return {
    id: id("prop"),
    name: name.trim(),
    type,
    options,
    sortOrder,
    isDefault: false,
    isVisible: true,
    dateModified: nowISO()
  };
}

export function defaultViews(): DatabaseViewRecord[] {
  const date = nowISO();
  return [
    {
      id: "view_all",
      name: "All References",
      icon: "Library",
      scope: { kind: "all" },
      columns: defaultColumns,
      filters: [],
      sorts: [{ target: { kind: "builtin", value: "dateAdded" }, ascending: false }],
      columnWraps: [],
      isDefault: true,
      displayOrder: 0,
      dateCreated: date,
      dateModified: date
    },
    {
      id: "view_reading",
      name: "Reading Queue",
      icon: "BookOpen",
      scope: { kind: "all" },
      columns: defaultColumns,
      filters: [
        {
          target: { kind: "builtin", value: "readingStatus" },
          op: "isAnyOf",
          value: { kind: "selectKeys", value: ["Unread", "Skimmed"] }
        }
      ],
      sorts: [{ target: { kind: "builtin", value: "dateAdded" }, ascending: false }],
      columnWraps: [],
      isDefault: false,
      displayOrder: 1,
      dateCreated: date,
      dateModified: date
    }
  ];
}

export function emptyReference(input: Partial<ReferenceRecord> = {}): ReferenceRecord {
  const date = nowISO();
  return {
    id: id("ref"),
    title: "",
    authors: [],
    dateAdded: date,
    dateModified: date,
    referenceType: "Journal Article",
    verificationStatus: "legacy",
    readingStatus: "Unread",
    readCount: 0,
    ...input
  };
}

export function tagOptionFromTag(tag: TagRecord): SelectOption {
  return { value: tag.name, color: tag.color };
}
