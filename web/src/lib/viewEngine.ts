import {
  ColumnIdentifier,
  DatabaseViewRecord,
  FieldTarget,
  FilterOperator,
  FilterValue,
  LibraryState,
  MaterializedReference,
  ReferenceRecord,
  ViewFilter,
  ViewSort
} from "./types";
import { authorDisplay } from "./model";

export function materializeReferences(state: LibraryState): MaterializedReference[] {
  const tagById = new Map(state.tags.map((tag) => [tag.id, tag]));
  const fileById = new Map(state.files.map((file) => [file.id, file]));
  const tagsByReference = new Map<string, string[]>();
  for (const relation of state.referenceTags) {
    const tags = tagsByReference.get(relation.referenceId) ?? [];
    tags.push(relation.tagId);
    tagsByReference.set(relation.referenceId, tags);
  }

  const valuesByReference = new Map<string, Record<string, string>>();
  for (const value of state.propertyValues) {
    const values = valuesByReference.get(value.referenceId) ?? {};
    values[value.propertyId] = value.value;
    valuesByReference.set(value.referenceId, values);
  }

  const annotationsByReference = new Map<string, typeof state.annotations>();
  for (const annotation of state.annotations) {
    const current = annotationsByReference.get(annotation.referenceId) ?? [];
    current.push(annotation);
    annotationsByReference.set(annotation.referenceId, current);
  }

  const pdfTextByReference = new Map<string, typeof state.pdfTextPages>();
  for (const page of state.pdfTextPages) {
    const current = pdfTextByReference.get(page.referenceId) ?? [];
    current.push(page);
    pdfTextByReference.set(page.referenceId, current);
  }

  return state.references.map((reference) => ({
    reference,
    tags: (tagsByReference.get(reference.id) ?? []).map((tagId) => tagById.get(tagId)).filter(Boolean),
    propertyValues: valuesByReference.get(reference.id) ?? {},
    annotations: annotationsByReference.get(reference.id) ?? [],
    pdfFile: reference.pdfFileId ? fileById.get(reference.pdfFileId) : undefined,
    pdfTextPages: pdfTextByReference.get(reference.id) ?? []
  })) as MaterializedReference[];
}

export function applyView(
  items: MaterializedReference[],
  view: DatabaseViewRecord | undefined,
  query: string
): MaterializedReference[] {
  const normalizedQuery = normalize(query);
  let result = items;
  const scope = view?.scope;
  if (scope?.kind === "tag") {
    result = result.filter((item) => item.tags.some((tag) => tag.id === scope.tagId));
  }
  if (view?.filters.length) {
    result = result.filter((item) => view.filters.every((filter) => evaluateFilter(item, filter)));
  }
  if (normalizedQuery) {
    result = result.filter((item) => haystack(item).includes(normalizedQuery));
  }
  const sorts: ViewSort[] = view?.sorts.length
    ? view.sorts
    : [{ target: { kind: "builtin", value: "dateAdded" }, ascending: false }];
  return [...result].sort((a, b) => compareBySorts(a, b, sorts));
}

export function groupItems(
  items: MaterializedReference[],
  view: DatabaseViewRecord | undefined
): Array<{ key: string; label: string; items: MaterializedReference[] }> {
  const groupBy = view?.groupBy;
  if (!groupBy) return [{ key: "all", label: "All", items }];
  const groups = new Map<string, MaterializedReference[]>();
  for (const item of items) {
    const raw = fieldValue(item, groupBy.target);
    const key = groupBy.dateBin ? dateBucket(raw, groupBy.dateBin) : displayValue(raw) || "Empty";
    const current = groups.get(key) ?? [];
    current.push(item);
    groups.set(key, current);
  }
  const order = groupBy.customOrder ?? [];
  return [...groups.entries()]
    .sort(([left], [right]) => {
      const leftIndex = order.indexOf(left);
      const rightIndex = order.indexOf(right);
      if (leftIndex >= 0 || rightIndex >= 0) return (leftIndex < 0 ? Number.MAX_SAFE_INTEGER : leftIndex) - (rightIndex < 0 ? Number.MAX_SAFE_INTEGER : rightIndex);
      return left.localeCompare(right);
    })
    .map(([key, grouped]) => ({ key, label: key, items: grouped }));
}

export function columnLabel(column: ColumnIdentifier): string {
  switch (column) {
    case "referenceType":
      return "Type";
    case "readingStatus":
      return "Status";
    case "dateAdded":
      return "Added";
    case "dateModified":
      return "Modified";
    case "pdfAttached":
      return "PDF";
    case "lastReadAt":
      return "Last Read";
    case "readCount":
      return "Read Count";
    default:
      return column.charAt(0).toUpperCase() + column.slice(1);
  }
}

export function displayField(item: MaterializedReference, target: FieldTarget): string {
  return displayValue(fieldValue(item, target));
}

function compareBySorts(a: MaterializedReference, b: MaterializedReference, sorts: ViewSort[]): number {
  for (const sort of sorts) {
    const left = fieldValue(a, sort.target);
    const right = fieldValue(b, sort.target);
    const compared = compareValues(left, right);
    if (compared !== 0) return sort.ascending ? compared : -compared;
  }
  return a.reference.title.localeCompare(b.reference.title);
}

function compareValues(left: unknown, right: unknown): number {
  if (left == null && right == null) return 0;
  if (left == null) return -1;
  if (right == null) return 1;
  if (typeof left === "number" && typeof right === "number") return left - right;
  return displayValue(left).localeCompare(displayValue(right), undefined, { numeric: true, sensitivity: "base" });
}

function evaluateFilter(item: MaterializedReference, filter: ViewFilter): boolean {
  const raw = fieldValue(item, filter.target);
  const value = displayValue(raw);
  const normalized = normalize(value);
  const filterValues = filterValueStrings(filter.value);
  const primary = normalize(filterValues[0] ?? "");

  switch (filter.op) {
    case "equals":
      return normalized === primary;
    case "notEquals":
      return normalized !== primary;
    case "contains":
      return normalized.includes(primary);
    case "notContains":
      return !normalized.includes(primary);
    case "startsWith":
      return normalized.startsWith(primary);
    case "endsWith":
      return normalized.endsWith(primary);
    case "greaterThan":
    case "greaterOrEqual":
    case "lessThan":
    case "lessOrEqual":
      return compareNumerically(raw, filter.value, filter.op);
    case "isAnyOf":
      return filterValues.map(normalize).includes(normalized);
    case "isNoneOf":
      return !filterValues.map(normalize).includes(normalized);
    case "containsAnyOf":
      return filterValues.some((candidate) => valueList(raw).map(normalize).includes(normalize(candidate)));
    case "containsNoneOf":
      return filterValues.every((candidate) => !valueList(raw).map(normalize).includes(normalize(candidate)));
    case "containsAllOf":
      return filterValues.every((candidate) => valueList(raw).map(normalize).includes(normalize(candidate)));
    case "isChecked":
      return raw === true || value === "true";
    case "isUnchecked":
      return raw !== true && value !== "true";
    case "isEmpty":
      return !value;
    case "isNotEmpty":
      return Boolean(value);
    default:
      return true;
  }
}

function compareNumerically(raw: unknown, filterValue: FilterValue, op: FilterOperator): boolean {
  const left =
    filterValue.kind === "date"
      ? new Date(displayValue(raw)).getTime()
      : typeof raw === "number"
        ? raw
        : Number(displayValue(raw));
  const right =
    filterValue.kind === "date"
      ? new Date(filterValue.value).getTime()
      : filterValue.kind === "number"
        ? filterValue.value
        : Number(filterValueStrings(filterValue)[0]);
  if (!Number.isFinite(left) || !Number.isFinite(right)) return false;
  if (op === "greaterThan") return left > right;
  if (op === "greaterOrEqual") return left >= right;
  if (op === "lessThan") return left < right;
  return left <= right;
}

function fieldValue(item: MaterializedReference, target: FieldTarget): unknown {
  if (target.kind === "custom") return item.propertyValues[target.value] ?? "";
  const ref = item.reference;
  switch (target.value) {
    case "authors":
      return authorDisplay(ref.authors);
    case "tags":
      return item.tags.map((tag) => tag.name);
    case "pdfAttached":
      return Boolean(item.pdfFile);
    default:
      return ref[target.value as keyof ReferenceRecord];
  }
}

function displayValue(value: unknown): string {
  if (value == null) return "";
  if (Array.isArray(value)) return value.join(", ");
  if (typeof value === "boolean") return value ? "true" : "false";
  return String(value);
}

function valueList(value: unknown): string[] {
  if (value == null) return [];
  if (Array.isArray(value)) return value.map(String);
  return String(value)
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function filterValueStrings(value: FilterValue): string[] {
  switch (value.kind) {
    case "selectKeys":
      return value.value;
    case "text":
    case "date":
      return [value.value];
    case "number":
      return [String(value.value)];
    case "bool":
      return [String(value.value)];
    case "none":
      return [];
  }
}

function haystack(item: MaterializedReference): string {
  const ref = item.reference;
  return normalize(
    [
      ref.title,
      authorDisplay(ref.authors),
      ref.year,
      ref.journal,
      ref.abstract,
      ref.notes,
      ref.doi,
      ref.url,
      ref.publisher,
      ref.readingStatus,
      ref.referenceType,
      item.pdfTextPages.map((page) => page.text).join(" "),
      item.tags.map((tag) => tag.name).join(" ")
    ]
      .filter(Boolean)
      .join(" ")
  );
}

function normalize(value: string): string {
  return value.toLowerCase().replace(/\s+/g, " ").trim();
}

function dateBucket(value: unknown, bin: "week" | "month" | "year"): string {
  const date = new Date(displayValue(value));
  if (Number.isNaN(date.getTime())) return "No date";
  if (bin === "year") return String(date.getFullYear());
  if (bin === "month") return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
  const start = new Date(date);
  start.setDate(date.getDate() - date.getDay());
  return `${start.getFullYear()}-${String(start.getMonth() + 1).padStart(2, "0")}-${String(start.getDate()).padStart(2, "0")}`;
}
