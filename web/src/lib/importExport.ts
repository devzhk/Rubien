import { emptyReference, id, nowISO, parseAuthors, stripBibTeXBraces } from "./model";
import { ReferenceRecord, ReferenceType, SerializedLibrarySnapshot } from "./types";
import { safeExternalURL } from "./url";
import { extractReadableHTML } from "./webExtract";

const bibtexTypeMap: Record<string, ReferenceType> = {
  article: "Journal Article",
  inproceedings: "Conference Paper",
  conference: "Conference Paper",
  book: "Book",
  phdthesis: "Thesis",
  mastersthesis: "Thesis",
  thesis: "Thesis",
  online: "Web Page",
  webpage: "Web Page",
  misc: "Other"
};

export function parseImportFile(name: string, text: string): ReferenceRecord[] | SerializedLibrarySnapshot {
  const lower = name.toLowerCase();
  if (lower.endsWith(".json")) {
    return JSON.parse(text) as SerializedLibrarySnapshot;
  }
  if (lower.endsWith(".md") || lower.endsWith(".markdown")) return [parseMarkdownDocument(name, text)];
  if (lower.endsWith(".html") || lower.endsWith(".htm")) return [parseHTMLDocument(name, text)];
  if (lower.endsWith(".ris") || /^\s*TY\s+-/m.test(text)) return parseRIS(text);
  const refs = parseBibTeX(text);
  if (refs.length > 0) return refs;
  return [parsePlainTextDocument(name, text)];
}

export function parseMarkdownDocument(name: string, text: string): ReferenceRecord {
  const title = text.match(/^\s*#\s+(.+)$/m)?.[1]?.trim() || titleFromFilename(name);
  return emptyReference({
    id: id("ref"),
    title,
    abstract: summarizePlainText(text),
    webContent: text,
    webContentFormat: "markdown",
    referenceType: "Markdown",
    metadataSource: "manual",
    verificationStatus: "seedOnly"
  });
}

export function parseHTMLDocument(name: string, text: string): ReferenceRecord {
  return extractReadableHTML(text, undefined, titleFromFilename(name)).reference;
}

export function parsePlainTextDocument(name: string, text: string): ReferenceRecord {
  const firstLine = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean);
  return emptyReference({
    id: id("ref"),
    title: firstLine?.slice(0, 120) || titleFromFilename(name),
    abstract: summarizePlainText(text),
    webContent: text,
    webContentFormat: "text",
    referenceType: "Markdown",
    metadataSource: "manual",
    verificationStatus: "seedOnly"
  });
}

export function parseBibTeX(source: string): ReferenceRecord[] {
  const entries = readBibTeXEntries(source);
  return entries.map(({ type, fields, key }) => {
    const date = nowISO();
    const year = numberFrom(fields.year ?? fields.date);
    const referenceType = bibtexTypeMap[type.toLowerCase()] ?? "Other";
    return emptyReference({
      id: id("ref"),
      title: fields.title ?? key ?? "Untitled",
      authors: parseAuthors(fields.author ?? ""),
      year,
      journal: fields.journal ?? fields.booktitle,
      volume: fields.volume,
      issue: fields.number,
      pages: fields.pages,
      doi: cleanDOI(fields.doi),
      url: safeExternalURL(fields.url),
      abstract: fields.abstract,
      dateAdded: date,
      dateModified: date,
      notes: fields.note,
      referenceType,
      metadataSource: "bibtex",
      verificationStatus: "legacy",
      publisher: fields.publisher,
      editors: fields.editor ? parseAuthors(fields.editor) : undefined,
      isbn: fields.isbn,
      issn: fields.issn,
      issuedMonth: monthFromBibTeX(fields.month),
      language: fields.language
    });
  });
}

export function parseRIS(source: string): ReferenceRecord[] {
  const records: Record<string, string[]>[] = [];
  let current: Record<string, string[]> = {};
  for (const line of source.split(/\r?\n/)) {
    const match = /^([A-Z0-9]{2})\s+-\s?(.*)$/.exec(line);
    if (!match) continue;
    const [, key, value] = match;
    if (key === "TY") current = { TY: [value.trim()] };
    else if (key === "ER") {
      records.push(current);
      current = {};
    } else {
      current[key] = [...(current[key] ?? []), value.trim()];
    }
  }
  // Push a trailing record that lacks a closing `ER` tag (truncated file, or
  // an exporter that omits the final `ER`) — otherwise it is silently dropped.
  if (Object.keys(current).length > 0) records.push(current);
  return records.map((fields) => {
    const date = nowISO();
    const title = first(fields.TI) ?? first(fields.T1) ?? first(fields.CT) ?? "Untitled";
    const issued = first(fields.PY) ?? first(fields.Y1) ?? first(fields.DA);
    const type = first(fields.TY)?.toUpperCase();
    // RIS `SN` carries an ISSN for serials and an ISBN otherwise. Route it to
    // the matching field so a round-trip (export writes ISSN into SN) restores
    // it correctly instead of turning every journal's ISSN into an ISBN.
    const serialNumber = first(fields.SN);
    const isJournal = risType(type) === "Journal Article";
    return emptyReference({
      id: id("ref"),
      title,
      authors: [...(fields.AU ?? []), ...(fields.A1 ?? [])].map(parseRisName),
      year: numberFrom(issued),
      journal: first(fields.JO) ?? first(fields.JF) ?? first(fields.T2),
      volume: first(fields.VL),
      issue: first(fields.IS),
      pages: [first(fields.SP), first(fields.EP)].filter(Boolean).join("-") || first(fields.PG),
      doi: cleanDOI(first(fields.DO)),
      url: safeExternalURL(first(fields.UR)),
      abstract: first(fields.AB) ?? first(fields.N2),
      dateAdded: date,
      dateModified: date,
      notes: first(fields.N1),
      referenceType: risType(type),
      metadataSource: "ris",
      verificationStatus: "legacy",
      publisher: first(fields.PB),
      isbn: isJournal ? undefined : serialNumber,
      issn: isJournal ? serialNumber : undefined,
      issuedMonth: monthFromRIS(issued),
      language: first(fields.LA)
    });
  });
}

export function exportBibTeX(references: ReferenceRecord[]): string {
  const used = new Set<string>();
  return references
    .map((ref) => {
      const type = bibtexType(ref.referenceType);
      const key = uniqueKey(ref, used);
      const fields: Array<[string, string | number | undefined]> = [
        ["title", ref.title],
        ["author", ref.authors.map((author) => (author.given ? `${author.family}, ${author.given}` : author.family)).join(" and ")],
        ["year", ref.year],
        ["journal", ref.journal],
        ["booktitle", ref.referenceType === "Conference Paper" ? ref.journal : undefined],
        ["volume", ref.volume],
        ["number", ref.issue],
        ["pages", ref.pages],
        ["doi", ref.doi],
        ["url", ref.url],
        ["abstract", ref.abstract],
        ["publisher", ref.publisher],
        ["isbn", ref.isbn],
        ["issn", ref.issn],
        ["note", ref.notes]
      ];
      const body = fields
        .filter(([, value]) => value != null && String(value).trim() !== "")
        .map(([field, value]) => `  ${field} = {${escapeBibTeX(String(value))}},`)
        .join("\n");
      return `@${type}{${key},\n${body}\n}`;
    })
    .join("\n\n");
}

export function exportRIS(references: ReferenceRecord[]): string {
  return references
    .map((ref) => {
      const lines = [`TY  - ${risExportType(ref.referenceType)}`];
      for (const author of ref.authors) lines.push(`AU  - ${author.family}${author.given ? `, ${author.given}` : ""}`);
      push(lines, "TI", ref.title);
      push(lines, "PY", ref.year?.toString());
      push(lines, "JO", ref.journal);
      push(lines, "VL", ref.volume);
      push(lines, "IS", ref.issue);
      push(lines, "SP", ref.pages?.split("-")[0]);
      push(lines, "EP", ref.pages?.split("-").slice(1).join("-"));
      push(lines, "DO", ref.doi);
      push(lines, "UR", ref.url);
      push(lines, "AB", ref.abstract);
      push(lines, "PB", ref.publisher);
      push(lines, "SN", ref.isbn ?? ref.issn);
      push(lines, "N1", ref.notes);
      lines.push("ER  -");
      return lines.join("\n");
    })
    .join("\n\n");
}

export function snapshotJSON(snapshot: SerializedLibrarySnapshot): string {
  return JSON.stringify({ ...snapshot, exportedAt: nowISO(), format: "rubien-web-v1" }, null, 2);
}

function readBibTeXEntries(source: string): Array<{ type: string; key?: string; fields: Record<string, string> }> {
  const entries: Array<{ type: string; key?: string; fields: Record<string, string> }> = [];
  let i = 0;
  while (i < source.length) {
    const at = source.indexOf("@", i);
    if (at < 0) break;
    const typeMatch = /^@([A-Za-z]+)\s*[{(]/.exec(source.slice(at));
    if (!typeMatch) {
      i = at + 1;
      continue;
    }
    const type = typeMatch[1];
    const open = at + typeMatch[0].length - 1;
    const close = findMatching(source, open);
    if (close < 0) break;
    const content = source.slice(open + 1, close);
    const comma = findTopLevelComma(content);
    const key = comma >= 0 ? content.slice(0, comma).trim() : undefined;
    const fieldSource = comma >= 0 ? content.slice(comma + 1) : content;
    entries.push({ type, key, fields: readBibTeXFields(fieldSource) });
    i = close + 1;
  }
  return entries;
}

function readBibTeXFields(source: string): Record<string, string> {
  const fields: Record<string, string> = {};
  let i = 0;
  while (i < source.length) {
    while (/[\s,]/.test(source[i] ?? "")) i += 1;
    const keyMatch = /^([A-Za-z][A-Za-z0-9_-]*)\s*=/.exec(source.slice(i));
    if (!keyMatch) break;
    const key = keyMatch[1].toLowerCase();
    i += keyMatch[0].length;
    while (/\s/.test(source[i] ?? "")) i += 1;
    const parsed = readBibTeXValue(source, i);
    fields[key] = stripBibTeXBraces(parsed.value);
    i = parsed.next;
  }
  return fields;
}

function readBibTeXValue(source: string, start: number): { value: string; next: number } {
  const quote = source[start];
  if (quote === "{" || quote === "\"") {
    const close = quote === "{" ? findMatching(source, start) : findQuote(source, start);
    return { value: source.slice(start + 1, close), next: close + 1 };
  }
  let end = start;
  while (end < source.length && source[end] !== ",") end += 1;
  return { value: source.slice(start, end).trim(), next: end + 1 };
}

function findMatching(source: string, open: number): number {
  const openChar = source[open];
  const closeChar = openChar === "{" ? "}" : ")";
  let depth = 0;
  let escaped = false;
  for (let i = open; i < source.length; i += 1) {
    const char = source[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === openChar) depth += 1;
    if (char === closeChar) {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function findQuote(source: string, open: number): number {
  let escaped = false;
  for (let i = open + 1; i < source.length; i += 1) {
    if (escaped) {
      escaped = false;
      continue;
    }
    if (source[i] === "\\") {
      escaped = true;
      continue;
    }
    if (source[i] === "\"") return i;
  }
  return source.length;
}

function findTopLevelComma(source: string): number {
  let depth = 0;
  for (let i = 0; i < source.length; i += 1) {
    if (source[i] === "{") depth += 1;
    if (source[i] === "}") depth -= 1;
    if (source[i] === "," && depth === 0) return i;
  }
  return -1;
}

function first(values?: string[]): string | undefined {
  return values?.find((value) => value.trim() !== "");
}

function numberFrom(value?: string): number | undefined {
  const match = value?.match(/\d{4}/);
  return match ? Number(match[0]) : undefined;
}

function cleanDOI(value?: string): string | undefined {
  return value?.replace(/^https?:\/\/(dx\.)?doi\.org\//i, "").trim();
}

function monthFromBibTeX(value?: string): number | undefined {
  if (!value) return undefined;
  const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
  const numeric = Number(value);
  if (numeric >= 1 && numeric <= 12) return numeric;
  const index = months.indexOf(value.toLowerCase().slice(0, 3));
  return index >= 0 ? index + 1 : undefined;
}

function monthFromRIS(value?: string): number | undefined {
  const match = value?.match(/^\d{4}[/-](\d{1,2})/);
  return match ? Number(match[1]) : undefined;
}

function parseRisName(value: string) {
  const [family, given = ""] = value.split(",").map((part) => part.trim());
  return { family, given };
}

function risType(type?: string): ReferenceType {
  switch (type) {
    case "JOUR":
      return "Journal Article";
    case "CPAPER":
    case "CONF":
      return "Conference Paper";
    case "BOOK":
      return "Book";
    case "THES":
      return "Thesis";
    case "WEB":
      return "Web Page";
    default:
      return "Other";
  }
}

function bibtexType(type: ReferenceType): string {
  switch (type) {
    case "Journal Article":
      return "article";
    case "Conference Paper":
      return "inproceedings";
    case "Book":
      return "book";
    case "Thesis":
      return "phdthesis";
    case "Web Page":
      return "online";
    default:
      return "misc";
  }
}

function risExportType(type: ReferenceType): string {
  switch (type) {
    case "Journal Article":
      return "JOUR";
    case "Conference Paper":
      return "CPAPER";
    case "Book":
      return "BOOK";
    case "Thesis":
      return "THES";
    case "Web Page":
      return "WEB";
    default:
      return "GEN";
  }
}

function uniqueKey(ref: ReferenceRecord, used: Set<string>): string {
  const author = ref.authors[0]?.family.replace(/[^A-Za-z0-9]/g, "") || "ref";
  const base = `${author}${ref.year ?? ""}` || "ref";
  let candidate = base;
  let suffix = 97;
  while (used.has(candidate)) {
    candidate = `${base}${String.fromCharCode(suffix)}`;
    suffix += 1;
  }
  used.add(candidate);
  return candidate;
}

function escapeBibTeX(value: string): string {
  // Strip our own brace grouping, then backslash-escape the LaTeX specials so
  // the exported .bib compiles in real BibTeX. `stripBibTeXBraces` unescapes
  // `\x` back to `x` on re-import, so this round-trips within Rubien too.
  return value.replace(/[{}]/g, "").replace(/([&%#_$])/g, "\\$1");
}

function push(lines: string[], key: string, value?: string): void {
  if (value?.trim()) lines.push(`${key}  - ${value.trim()}`);
}

function titleFromFilename(name: string): string {
  return name.replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ").trim() || "Imported document";
}

function summarizePlainText(text: string): string | undefined {
  const summary = text.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 360);
  return summary || undefined;
}
