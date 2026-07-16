import {
  BookOpen,
  Check,
  ChevronDown,
  Download,
  FileText,
  Filter,
  Globe,
  Highlighter,
  Import,
  Library,
  Link,
  ListFilter,
  Loader2,
  NotebookPen,
  PanelRight,
  Plus,
  RefreshCw,
  Search,
  Settings2,
  Tags,
  Trash2,
  Upload
} from "lucide-react";
import { ChangeEvent, PointerEvent, useEffect, useMemo, useRef, useState } from "react";
import {
  addReferences,
  attachPDF,
  deleteAnnotation,
  deleteReference,
  exportSnapshot,
  getPDFTextPages,
  importSnapshot,
  loadLibraryState,
  markReferenceRead,
  putAnnotation,
  putProperty,
  putPropertyValue,
  putReference,
  putView,
  replacePDFTextPages,
  setReferenceTags,
  upsertTag
} from "./lib/db";
import { CitationStyle, formatBibliography, formatInlineCitation, supportedCitationStyles } from "./lib/citations";
import { renderStoredContent } from "./lib/content";
import { normalizedRectFromPoints, rectToPercentStyle } from "./lib/geometry";
import { exportBibTeX, exportRIS, parseImportFile, snapshotJSON } from "./lib/importExport";
import {
  authorDisplay,
  customPropertyFromInput,
  defaultColumns,
  emptyReference,
  id,
  nextUnusedColor,
  nowISO,
  parseAuthors
} from "./lib/model";
import { resolveLocator } from "./lib/metadata";
import { searchPDFText } from "./lib/pdfSearch";
import {
  AnnotationRecord,
  AnnotationType,
  ColumnIdentifier,
  DatabaseViewRecord,
  FieldTarget,
  FilterOperator,
  FilterValue,
  LibrarySnapshot,
  LibraryState,
  MaterializedReference,
  PropertyDefinitionRecord,
  PropertyType,
  ReferenceRecord,
  ReferenceType,
  SelectOption,
  StoredFileRecord,
  TagRecord,
  ViewFilter,
  referenceTypes,
  readingStatuses
} from "./lib/types";
import { applyView, columnLabel, displayField, groupItems, materializeReferences } from "./lib/viewEngine";
import { extractReadableHTML, fetchReadableURL } from "./lib/webExtract";

const emptyState: LibraryState = {
  references: [],
  tags: [],
  referenceTags: [],
  properties: [],
  propertyValues: [],
  views: [],
  annotations: [],
  files: [],
  pdfTextPages: []
};

type DetailTab = "details" | "reader" | "notes" | "cite" | "properties";

export function App() {
  const [state, setState] = useState<LibraryState>(emptyState);
  const [selectedViewId, setSelectedViewId] = useState("view_all");
  const [selectedReferenceId, setSelectedReferenceId] = useState<string | undefined>();
  const [query, setQuery] = useState("");
  const [locator, setLocator] = useState("");
  const [busy, setBusy] = useState<string | undefined>();
  const [error, setError] = useState<string | undefined>();
  const [tab, setTab] = useState<DetailTab>("details");
  const [captureOpen, setCaptureOpen] = useState(false);

  async function refresh(selectReferenceId?: string) {
    const next = await loadLibraryState();
    setState(next);
    if (selectReferenceId) setSelectedReferenceId(selectReferenceId);
    else if (selectedReferenceId && !next.references.some((ref) => ref.id === selectedReferenceId)) {
      setSelectedReferenceId(next.references[0]?.id);
    }
  }

  useEffect(() => {
    refresh().catch((err: unknown) => setError(String(err)));
  }, []);

  const views = [...state.views].sort((a, b) => a.displayOrder - b.displayOrder);
  const selectedView = views.find((view) => view.id === selectedViewId) ?? views[0];
  const materialized = useMemo(() => materializeReferences(state), [state]);
  const visibleItems = useMemo(
    () => applyView(materialized, selectedView, query),
    [materialized, selectedView, query]
  );
  const groupedItems = useMemo(() => groupItems(visibleItems, selectedView), [visibleItems, selectedView]);
  const selectedItem =
    materialized.find((item) => item.reference.id === selectedReferenceId) ?? visibleItems[0] ?? materialized[0];

  async function run<T>(label: string, action: () => Promise<T>): Promise<T | undefined> {
    setBusy(label);
    setError(undefined);
    try {
      return await action();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      return undefined;
    } finally {
      setBusy(undefined);
    }
  }

  async function addManualReference() {
    await run("Creating reference", async () => {
      const ref = emptyReference({ title: "Untitled reference", metadataSource: "manual" });
      await putReference(ref);
      await refresh(ref.id);
    });
  }

  async function addByLocator() {
    const input = locator.trim();
    if (!input) return;
    await run("Resolving metadata", async () => {
      const ref = await resolveLocator(input);
      await putReference(ref);
      setLocator("");
      await refresh(ref.id);
    });
  }

  async function handleImport(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    await run("Importing", async () => {
      const text = await file.text();
      const parsed = parseImportFile(file.name, text);
      if (Array.isArray(parsed)) {
        await addReferences(parsed);
        await refresh(parsed[0]?.id);
      } else {
        await importSnapshot(parsed as LibrarySnapshot);
        await refresh();
      }
    });
  }

  async function exportVisible(format: "json" | "bibtex" | "ris") {
    await run("Exporting", async () => {
      const references = visibleItems.map((item) => item.reference);
      const content =
        format === "bibtex"
          ? exportBibTeX(references)
          : format === "ris"
            ? exportRIS(references)
            : snapshotJSON(await exportSnapshot());
      downloadText(
        content,
        `rubien-${format === "json" ? "web-export.json" : `references.${format === "bibtex" ? "bib" : "ris"}`}`,
        format === "json" ? "application/json" : "text/plain"
      );
    });
  }

  async function saveReference(reference: ReferenceRecord, tagsText: string, propertyValues: Record<string, string>) {
    await run("Saving", async () => {
      await putReference(reference);
      const tagNames = tagsText.split(",").map((tag) => tag.trim()).filter(Boolean);
      const tags: TagRecord[] = [];
      for (const name of tagNames) {
        const tag = await upsertTag(name, state.tags.map((item) => item.color), nextUnusedColor(state.tags.map((item) => item.color)));
        tags.push(tag);
      }
      await setReferenceTags(reference.id, tags.map((tag) => tag.id));
      for (const [propertyId, value] of Object.entries(propertyValues)) {
        await putPropertyValue(reference.id, propertyId, value);
      }
      await refresh(reference.id);
    });
  }

  async function addCustomProperty(name: string, type: PropertyType, optionsText: string) {
    await run("Adding property", async () => {
      if (!name.trim()) return;
      const property = customPropertyFromInput(name, type, optionsText, state.properties.length);
      await putProperty(property);
      await refresh(selectedReferenceId);
    });
  }

  async function createTagView(tag: TagRecord) {
    const view: DatabaseViewRecord = {
      id: id("view"),
      name: tag.name,
      icon: "Tags",
      scope: { kind: "tag", tagId: tag.id },
      columns: defaultColumns,
      filters: [],
      sorts: [{ target: { kind: "builtin", value: "dateAdded" }, ascending: false }],
      columnWraps: [],
      isDefault: false,
      displayOrder: views.length,
      dateCreated: nowISO(),
      dateModified: nowISO()
    };
    await putView(view);
    await refresh();
    setSelectedViewId(view.id);
  }

  async function deleteSelected() {
    if (!selectedItem) return;
    if (!window.confirm(`Delete "${selectedItem.reference.title}"?`)) return;
    await run("Deleting", async () => {
      await deleteReference(selectedItem.reference.id);
      await refresh();
    });
  }

  async function captureURL(url: string) {
    await run("Capturing URL", async () => {
      const extracted = await fetchReadableURL(url);
      await putReference(extracted.reference);
      await refresh(extracted.reference.id);
      setTab("reader");
    });
  }

  async function captureHTML(html: string, sourceUrl?: string) {
    await run("Capturing HTML", async () => {
      const extracted = extractReadableHTML(html, sourceUrl);
      await putReference(extracted.reference);
      await refresh(extracted.reference.id);
      setTab("reader");
    });
  }

  return (
    <div className="app-shell">
      <Sidebar
        views={views}
        selectedViewId={selectedView?.id}
        tags={state.tags}
        properties={state.properties}
        selectedView={selectedView}
        onSelectView={setSelectedViewId}
        onUpdateView={async (view) => {
          await putView(view);
          await refresh(selectedReferenceId);
        }}
        onCreateTagView={createTagView}
      />
      <main className="workspace">
        <header className="toolbar">
          <div className="search-box">
            <Search size={16} />
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search title, authors, tags, DOI" />
          </div>
          <div className="locator-box">
            <Link size={16} />
            <input
              value={locator}
              onChange={(event) => setLocator(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") addByLocator();
              }}
              placeholder="DOI, arXiv, ISBN, URL, or title"
            />
            <button type="button" className="icon-button" title="Resolve metadata" onClick={addByLocator} disabled={Boolean(busy)}>
              {busy === "Resolving metadata" ? <Loader2 className="spin" size={16} /> : <RefreshCw size={16} />}
            </button>
          </div>
          <button type="button" className="text-button" onClick={addManualReference}>
            <Plus size={16} />
            Add
          </button>
          <button type="button" className="text-button" onClick={() => setCaptureOpen((value) => !value)}>
            <Globe size={16} />
            Capture
          </button>
          <label className="text-button file-button">
            <Import size={16} />
            Import
            <input type="file" accept=".bib,.ris,.json,.html,.htm,.md,.markdown,text/*,application/json,text/html,text/markdown" onChange={handleImport} />
          </label>
          <ExportMenu onExport={exportVisible} />
        </header>
        {captureOpen ? <WebCapturePanel onCaptureURL={captureURL} onCaptureHTML={captureHTML} busy={busy} /> : null}
        {error ? <div className="error-strip">{error}</div> : null}
        <section className="content-grid">
          <ReferenceTable
            groups={groupedItems}
            selectedId={selectedItem?.reference.id}
            view={selectedView}
            onSelect={(item) => {
              setSelectedReferenceId(item.reference.id);
              setTab("details");
            }}
          />
          <DetailPane
            item={selectedItem}
            state={state}
            tab={tab}
            onTab={setTab}
            onSave={saveReference}
            onDelete={deleteSelected}
            onAddProperty={addCustomProperty}
            onAttachPDF={async (referenceId, file) => {
              await run("Attaching PDF", async () => {
                await attachPDF(referenceId, file);
                await refresh(referenceId);
              });
            }}
            onMarkRead={async (reference) => {
              await markReferenceRead(reference);
              await refresh(reference.id);
            }}
            onPutAnnotation={async (annotation) => {
              await putAnnotation(annotation);
              await refresh(annotation.referenceId);
            }}
            onDeleteAnnotation={async (annotation) => {
              await deleteAnnotation(annotation.id);
              await refresh(annotation.referenceId);
            }}
          />
        </section>
        <footer className="statusbar">
          <span>{visibleItems.length} shown</span>
          <span>{state.references.length} total</span>
          <span>{state.files.length} local PDFs</span>
          <span>{busy ?? "Ready"}</span>
        </footer>
      </main>
    </div>
  );
}

function Sidebar({
  views,
  selectedViewId,
  tags,
  properties,
  selectedView,
  onSelectView,
  onUpdateView,
  onCreateTagView
}: {
  views: DatabaseViewRecord[];
  selectedViewId?: string;
  tags: TagRecord[];
  properties: PropertyDefinitionRecord[];
  selectedView?: DatabaseViewRecord;
  onSelectView: (id: string) => void;
  onUpdateView: (view: DatabaseViewRecord) => void;
  onCreateTagView: (tag: TagRecord) => void;
}) {
  return (
    <aside className="sidebar">
      <div className="brand-row">
        <div className="brand-mark">
          <Library size={18} />
        </div>
        <div>
          <strong>Rubien</strong>
          <span>Web</span>
        </div>
      </div>
      <nav className="view-list">
        {views.map((view) => (
          <button
            key={view.id}
            type="button"
            className={view.id === selectedViewId ? "selected" : ""}
            onClick={() => onSelectView(view.id)}
          >
            {view.icon === "BookOpen" ? <BookOpen size={15} /> : view.icon === "Tags" ? <Tags size={15} /> : <Library size={15} />}
            {view.name}
          </button>
        ))}
      </nav>
      <section className="sidebar-section">
        <div className="section-title">
          <Tags size={14} />
          Tags
        </div>
        <div className="tag-stack">
          {tags.map((tag) => (
            <button key={tag.id} type="button" className="tag-chip" onClick={() => onCreateTagView(tag)}>
              <span style={{ background: tag.color }} />
              {tag.name}
            </button>
          ))}
        </div>
      </section>
      {selectedView ? <ViewEditor view={selectedView} properties={properties} tags={tags} onUpdate={onUpdateView} /> : null}
    </aside>
  );
}

function WebCapturePanel({
  onCaptureURL,
  onCaptureHTML,
  busy
}: {
  onCaptureURL: (url: string) => void;
  onCaptureHTML: (html: string, sourceUrl?: string) => void;
  busy?: string;
}) {
  const [url, setUrl] = useState("");
  const [html, setHTML] = useState("");
  const [sourceUrl, setSourceUrl] = useState("");

  return (
    <section className="capture-panel">
      <div className="capture-grid">
        <label className="field">
          <span>URL</span>
          <input
            value={url}
            onChange={(event) => {
              setUrl(event.target.value);
              if (!sourceUrl) setSourceUrl(event.target.value);
            }}
            placeholder="https://example.org/article"
          />
        </label>
        <button type="button" className="text-button primary" onClick={() => onCaptureURL(url)} disabled={!url.trim() || Boolean(busy)}>
          {busy === "Capturing URL" ? <Loader2 className="spin" size={15} /> : <Globe size={15} />}
          Fetch
        </button>
      </div>
      <div className="capture-grid capture-paste">
        <label className="field">
          <span>Source URL</span>
          <input value={sourceUrl} onChange={(event) => setSourceUrl(event.target.value)} placeholder="Optional original page URL" />
        </label>
        <label className="field wide">
          <span>Saved page HTML</span>
          <textarea
            value={html}
            onChange={(event) => setHTML(event.target.value)}
            placeholder="Paste a saved page, article body, or browser selection HTML when direct URL fetch is blocked."
          />
        </label>
        <button type="button" className="text-button" onClick={() => onCaptureHTML(html, sourceUrl)} disabled={!html.trim() || Boolean(busy)}>
          {busy === "Capturing HTML" ? <Loader2 className="spin" size={15} /> : <Import size={15} />}
          Save HTML
        </button>
      </div>
    </section>
  );
}

function ViewEditor({
  view,
  properties,
  tags,
  onUpdate
}: {
  view: DatabaseViewRecord;
  properties: PropertyDefinitionRecord[];
  tags: TagRecord[];
  onUpdate: (view: DatabaseViewRecord) => void;
}) {
  const statusFilter = view.filters.find(
    (filter) => filter.target.kind === "builtin" && filter.target.value === "readingStatus" && filter.op === "isAnyOf"
  );
  const selectedStatuses = statusFilter?.value.kind === "selectKeys" ? statusFilter.value.value : [];
  const visibleColumns = new Set(view.columns.filter((column) => column.isVisible).map((column) => column.columnId));
  const sort = view.sorts[0] ?? { target: { kind: "builtin" as const, value: "dateAdded" as ColumnIdentifier }, ascending: false };

  function setStatusFilter(status: string, checked: boolean) {
    const next = checked ? [...selectedStatuses, status] : selectedStatuses.filter((value) => value !== status);
    const others = view.filters.filter((filter) => filter !== statusFilter);
    onUpdate({
      ...view,
      filters: next.length
        ? [
            ...others,
            {
              target: { kind: "builtin", value: "readingStatus" },
              op: "isAnyOf",
              value: { kind: "selectKeys", value: next }
            }
          ]
        : others
    });
  }

  function setColumn(columnId: ColumnIdentifier, checked: boolean) {
    onUpdate({
      ...view,
      columns: view.columns.map((column) => (column.columnId === columnId ? { ...column, isVisible: checked } : column))
    });
  }

  function setFilter(index: number, filter: ViewFilter) {
    onUpdate({
      ...view,
      filters: view.filters.map((item, itemIndex) => (itemIndex === index ? filter : item))
    });
  }

  function addFilter() {
    onUpdate({
      ...view,
      filters: [
        ...view.filters,
        {
          target: { kind: "builtin", value: "title" },
          op: "contains",
          value: { kind: "text", value: "" }
        }
      ]
    });
  }

  function removeFilter(index: number) {
    onUpdate({
      ...view,
      filters: view.filters.filter((_, itemIndex) => itemIndex !== index)
    });
  }

  return (
    <section className="sidebar-section view-editor">
      <div className="section-title">
        <Settings2 size={14} />
        View
      </div>
      <label>
        <span>Sort</span>
        <select
          value={sort.target.kind === "builtin" ? sort.target.value : "dateAdded"}
          onChange={(event) =>
            onUpdate({
              ...view,
              sorts: [{ target: { kind: "builtin", value: event.target.value as ColumnIdentifier }, ascending: sort.ascending }]
            })
          }
        >
          {(["dateAdded", "title", "year", "journal", "readingStatus", "lastReadAt", "readCount"] as ColumnIdentifier[]).map((column) => (
            <option key={column} value={column}>
              {columnLabel(column)}
            </option>
          ))}
        </select>
      </label>
      <label className="inline-check">
        <input
          type="checkbox"
          checked={sort.ascending}
          onChange={(event) => onUpdate({ ...view, sorts: [{ ...sort, ascending: event.target.checked }] })}
        />
        Ascending
      </label>
      <label>
        <span>Group</span>
        <select
          value={view.groupBy?.target.kind === "builtin" ? view.groupBy.target.value : ""}
          onChange={(event) =>
            onUpdate({
              ...view,
              groupBy: event.target.value
                ? {
                    target: { kind: "builtin", value: event.target.value as ColumnIdentifier },
                    collapsed: [],
                    showEmpty: true
                  }
                : undefined
            })
          }
        >
          <option value="">None</option>
          {(["readingStatus", "referenceType", "journal", "year", "dateAdded"] as ColumnIdentifier[]).map((column) => (
            <option key={column} value={column}>
              {columnLabel(column)}
            </option>
          ))}
        </select>
      </label>
      <div className="check-grid">
        {readingStatuses.map((status) => (
          <label key={status} className="inline-check">
            <input
              type="checkbox"
              checked={selectedStatuses.includes(status)}
              onChange={(event) => setStatusFilter(status, event.target.checked)}
            />
            {status}
          </label>
        ))}
      </div>
      <details open>
        <summary>
          <Filter size={14} />
          Filters
        </summary>
        <div className="filter-stack">
          {view.filters.map((filter, index) => (
            <ViewFilterRow
              key={index}
              filter={filter}
              properties={properties}
              tags={tags}
              onChange={(next) => setFilter(index, next)}
              onRemove={() => removeFilter(index)}
            />
          ))}
          <button type="button" className="text-button" onClick={addFilter}>
            <Plus size={14} />
            Filter
          </button>
        </div>
      </details>
      <details>
        <summary>
          <ListFilter size={14} />
          Columns
        </summary>
        <div className="check-grid">
          {view.columns.map((column) => (
            <label key={column.columnId} className="inline-check">
              <input
                type="checkbox"
                checked={visibleColumns.has(column.columnId)}
                onChange={(event) => setColumn(column.columnId, event.target.checked)}
              />
              {columnLabel(column.columnId)}
            </label>
          ))}
        </div>
      </details>
    </section>
  );
}

type FilterFieldType = PropertyType | "text" | "singleSelect" | "multiSelect" | "date" | "number" | "checkbox";

interface FilterTargetOption {
  key: string;
  label: string;
  target: FieldTarget;
  type: FilterFieldType;
  options: SelectOption[];
}

function ViewFilterRow({
  filter,
  properties,
  tags,
  onChange,
  onRemove
}: {
  filter: ViewFilter;
  properties: PropertyDefinitionRecord[];
  tags: TagRecord[];
  onChange: (filter: ViewFilter) => void;
  onRemove: () => void;
}) {
  const targets = filterTargetOptions(properties, tags);
  const selectedKey = targetKey(filter.target);
  const selectedTarget = targets.find((target) => target.key === selectedKey) ?? targets[0];
  const operators = operatorOptions(selectedTarget.type);
  const operator = operators.some((option) => option.value === filter.op) ? filter.op : operators[0].value;

  function setTarget(key: string) {
    const next = targets.find((target) => target.key === key) ?? targets[0];
    const op = operatorOptions(next.type)[0].value;
    onChange({
      target: next.target,
      op,
      value: defaultFilterValue(next.type, next.options)
    });
  }

  function setOperator(op: FilterOperator) {
    onChange({
      ...filter,
      op,
      value: operatorHasValue(op) ? filter.value : { kind: "none" }
    });
  }

  return (
    <div className="filter-row">
      <select value={selectedKey} onChange={(event) => setTarget(event.target.value)} aria-label="Filter field">
        {targets.map((target) => (
          <option key={target.key} value={target.key}>
            {target.label}
          </option>
        ))}
      </select>
      <select value={operator} onChange={(event) => setOperator(event.target.value as FilterOperator)} aria-label="Filter operator">
        {operators.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
      <FilterValueControl
        type={selectedTarget.type}
        options={selectedTarget.options}
        op={operator}
        value={filter.value}
        onChange={(value) => onChange({ ...filter, op: operator, value })}
      />
      <button type="button" className="icon-button danger" title="Remove filter" onClick={onRemove}>
        <Trash2 size={14} />
      </button>
    </div>
  );
}

function FilterValueControl({
  type,
  options,
  op,
  value,
  onChange
}: {
  type: FilterFieldType;
  options: SelectOption[];
  op: FilterOperator;
  value: FilterValue;
  onChange: (value: FilterValue) => void;
}) {
  if (!operatorHasValue(op)) return <div className="filter-value-empty" />;
  if (type === "checkbox") return <div className="filter-value-empty" />;

  if (type === "singleSelect" || type === "multiSelect") {
    const selected = new Set(value.kind === "selectKeys" ? value.value : filterValueText(value).split(",").map((item) => item.trim()).filter(Boolean));
    if (options.length === 0) {
      return (
        <input
          value={[...selected].join(", ")}
          onChange={(event) => onChange({ kind: "selectKeys", value: commaList(event.target.value) })}
          placeholder="Values"
          aria-label="Filter values"
        />
      );
    }
    return (
      <div className="filter-option-list">
        {options.map((option) => (
          <label key={option.value} className="inline-check">
            <input
              type="checkbox"
              checked={selected.has(option.value)}
              onChange={(event) => {
                const next = new Set(selected);
                if (event.target.checked) next.add(option.value);
                else next.delete(option.value);
                onChange({ kind: "selectKeys", value: [...next] });
              }}
            />
            <span className="option-dot" style={{ background: option.color }} />
            {option.value}
          </label>
        ))}
      </div>
    );
  }

  if (type === "number") {
    return (
      <input
        type="number"
        value={value.kind === "number" ? value.value : filterValueText(value)}
        onChange={(event) => onChange({ kind: "number", value: Number(event.target.value) })}
        aria-label="Filter number"
      />
    );
  }

  if (type === "date") {
    return (
      <input
        type="date"
        value={value.kind === "date" ? value.value.slice(0, 10) : filterValueText(value)}
        onChange={(event) => onChange({ kind: "date", value: event.target.value })}
        aria-label="Filter date"
      />
    );
  }

  return (
    <input
      value={filterValueText(value)}
      onChange={(event) => onChange({ kind: "text", value: event.target.value })}
      placeholder="Value"
      aria-label="Filter text"
    />
  );
}

function filterTargetOptions(properties: PropertyDefinitionRecord[], tags: TagRecord[]): FilterTargetOption[] {
  const builtins: Array<[ColumnIdentifier, FilterFieldType, SelectOption[]]> = [
    ["title", "text", []],
    ["authors", "text", []],
    ["year", "number", []],
    ["journal", "text", []],
    ["referenceType", "singleSelect", referenceTypes.map((value, index) => ({ value, color: colorPaletteColor(index) }))],
    ["tags", "multiSelect", tags.map((tag) => ({ value: tag.name, color: tag.color }))],
    ["readingStatus", "singleSelect", readingStatuses.map((value, index) => ({ value, color: colorPaletteColor(index) }))],
    ["dateAdded", "date", []],
    ["dateModified", "date", []],
    ["doi", "text", []],
    ["publisher", "text", []],
    ["volume", "text", []],
    ["issue", "text", []],
    ["pages", "text", []],
    ["pdfAttached", "checkbox", []],
    ["lastReadAt", "date", []],
    ["readCount", "number", []]
  ];

  return [
    ...builtins.map(([column, type, options]) => ({
      key: `builtin:${column}`,
      label: columnLabel(column),
      target: { kind: "builtin" as const, value: column },
      type,
      options
    })),
    ...properties
      .filter((property) => !property.isDefault)
      .map((property) => ({
        key: `custom:${property.id}`,
        label: property.name,
        target: { kind: "custom" as const, value: property.id },
        type: property.type,
        options: property.options
      }))
  ];
}

function operatorOptions(type: FilterFieldType): Array<{ value: FilterOperator; label: string }> {
  const commonEmpty = [
    { value: "isEmpty" as const, label: "is empty" },
    { value: "isNotEmpty" as const, label: "is not empty" }
  ];
  if (type === "checkbox") {
    return [
      { value: "isChecked", label: "is checked" },
      { value: "isUnchecked", label: "is unchecked" }
    ];
  }
  if (type === "singleSelect") {
    return [
      { value: "isAnyOf", label: "is any of" },
      { value: "isNoneOf", label: "is none of" },
      ...commonEmpty
    ];
  }
  if (type === "multiSelect") {
    return [
      { value: "containsAnyOf", label: "contains any" },
      { value: "containsAllOf", label: "contains all" },
      { value: "containsNoneOf", label: "contains none" },
      ...commonEmpty
    ];
  }
  if (type === "number" || type === "date") {
    return [
      { value: "equals", label: "equals" },
      { value: "notEquals", label: "does not equal" },
      { value: "greaterThan", label: "is greater than" },
      { value: "lessThan", label: "is less than" },
      { value: "greaterOrEqual", label: "is at least" },
      { value: "lessOrEqual", label: "is at most" },
      ...commonEmpty
    ];
  }
  return [
    { value: "contains", label: "contains" },
    { value: "notContains", label: "does not contain" },
    { value: "equals", label: "equals" },
    { value: "notEquals", label: "does not equal" },
    { value: "startsWith", label: "starts with" },
    { value: "endsWith", label: "ends with" },
    ...commonEmpty
  ];
}

function defaultFilterValue(type: FilterFieldType, options: SelectOption[]): FilterValue {
  if (type === "number") return { kind: "number", value: 0 };
  if (type === "date") return { kind: "date", value: new Date().toISOString().slice(0, 10) };
  if (type === "checkbox") return { kind: "none" };
  if (type === "singleSelect" || type === "multiSelect") return { kind: "selectKeys", value: options[0] ? [options[0].value] : [] };
  return { kind: "text", value: "" };
}

function operatorHasValue(op: FilterOperator): boolean {
  return !["isEmpty", "isNotEmpty", "isChecked", "isUnchecked"].includes(op);
}

function targetKey(target: FieldTarget): string {
  return `${target.kind}:${target.value}`;
}

function filterValueText(value: FilterValue): string {
  switch (value.kind) {
    case "text":
    case "date":
      return value.value;
    case "number":
      return String(value.value);
    case "selectKeys":
      return value.value.join(", ");
    case "bool":
      return String(value.value);
    case "none":
      return "";
  }
}

function commaList(value: string): string[] {
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}

function colorPaletteColor(index: number): string {
  const colors = ["#007AFF", "#34C759", "#FF9500", "#FF3B30", "#AF52DE", "#5AC8FA", "#FF2D55"];
  return colors[index % colors.length];
}

function ExportMenu({ onExport }: { onExport: (format: "json" | "bibtex" | "ris") => void }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="menu-wrap">
      <button type="button" className="text-button" onClick={() => setOpen((value) => !value)}>
        <Download size={16} />
        Export
        <ChevronDown size={14} />
      </button>
      {open ? (
        <div className="menu">
          <button type="button" onClick={() => onExport("json")}>
            JSON snapshot
          </button>
          <button type="button" onClick={() => onExport("bibtex")}>
            BibTeX
          </button>
          <button type="button" onClick={() => onExport("ris")}>
            RIS
          </button>
        </div>
      ) : null}
    </div>
  );
}

function ReferenceTable({
  groups,
  selectedId,
  view,
  onSelect
}: {
  groups: Array<{ key: string; label: string; items: MaterializedReference[] }>;
  selectedId?: string;
  view?: DatabaseViewRecord;
  onSelect: (item: MaterializedReference) => void;
}) {
  const columns = (view?.columns ?? defaultColumns).filter((column) => column.isVisible).sort((a, b) => a.displayOrder - b.displayOrder);
  if (groups.every((group) => group.items.length === 0)) {
    return (
      <section className="table-pane empty-pane">
        <FileText size={28} />
        <h2>No references</h2>
      </section>
    );
  }
  return (
    <section className="table-pane">
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              {columns.map((column) => (
                <th key={column.columnId}>{columnLabel(column.columnId)}</th>
              ))}
            </tr>
          </thead>
          {groups.map((group) => (
            <tbody key={group.key}>
              {groups.length > 1 ? (
                <tr className="group-row">
                  <td colSpan={columns.length}>{group.label}</td>
                </tr>
              ) : null}
              {group.items.map((item) => (
                <tr
                  key={item.reference.id}
                  className={item.reference.id === selectedId ? "selected" : ""}
                  onClick={() => onSelect(item)}
                >
                  {columns.map((column) => (
                    <td key={column.columnId}>{renderCell(item, column.columnId)}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          ))}
        </table>
      </div>
    </section>
  );
}

function DetailPane({
  item,
  state,
  tab,
  onTab,
  onSave,
  onDelete,
  onAddProperty,
  onAttachPDF,
  onMarkRead,
  onPutAnnotation,
  onDeleteAnnotation
}: {
  item?: MaterializedReference;
  state: LibraryState;
  tab: DetailTab;
  onTab: (tab: DetailTab) => void;
  onSave: (reference: ReferenceRecord, tagsText: string, propertyValues: Record<string, string>) => void;
  onDelete: () => void;
  onAddProperty: (name: string, type: PropertyType, optionsText: string) => void;
  onAttachPDF: (referenceId: string, file: File) => void;
  onMarkRead: (reference: ReferenceRecord) => void;
  onPutAnnotation: (annotation: AnnotationRecord) => void;
  onDeleteAnnotation: (annotation: AnnotationRecord) => void;
}) {
  const [draft, setDraft] = useState<ReferenceRecord | undefined>(item?.reference);
  const [tagsText, setTagsText] = useState("");
  const [propertyValues, setPropertyValues] = useState<Record<string, string>>({});
  const [citationStyle, setCitationStyle] = useState<CitationStyle>("apa");

  useEffect(() => {
    setDraft(item?.reference);
    setTagsText(item?.tags.map((tag) => tag.name).join(", ") ?? "");
    setPropertyValues(item?.propertyValues ?? {});
  }, [item?.reference.id]);

  if (!item || !draft) {
    return (
      <aside className="detail-pane empty-pane">
        <PanelRight size={28} />
        <h2>Select a reference</h2>
      </aside>
    );
  }

  const customProperties = state.properties.filter((property) => !property.isDefault);

  return (
    <aside className="detail-pane">
      <div className="detail-header">
        <div>
          <h1>{draft.title || "Untitled"}</h1>
          <p>{authorDisplay(draft.authors) || draft.referenceType}</p>
        </div>
        <button type="button" className="icon-button danger" title="Delete" onClick={onDelete}>
          <Trash2 size={16} />
        </button>
      </div>
      <div className="tab-strip">
        <button className={tab === "details" ? "selected" : ""} type="button" onClick={() => onTab("details")}>
          <FileText size={15} />
          Details
        </button>
        <button className={tab === "reader" ? "selected" : ""} type="button" onClick={() => onTab("reader")}>
          <BookOpen size={15} />
          Reader
        </button>
        <button className={tab === "notes" ? "selected" : ""} type="button" onClick={() => onTab("notes")}>
          <NotebookPen size={15} />
          Notes
        </button>
        <button className={tab === "cite" ? "selected" : ""} type="button" onClick={() => onTab("cite")}>
          <Highlighter size={15} />
          Cite
        </button>
        <button className={tab === "properties" ? "selected" : ""} type="button" onClick={() => onTab("properties")}>
          <Filter size={15} />
          Props
        </button>
      </div>
      <div className="detail-body">
        {tab === "details" ? (
          <DetailsForm draft={draft} tagsText={tagsText} onDraft={setDraft} onTagsText={setTagsText} />
        ) : null}
        {tab === "reader" ? (
          <ReaderPanel
            item={item}
            onAttachPDF={onAttachPDF}
            onMarkRead={onMarkRead}
            onPutAnnotation={onPutAnnotation}
            onDeleteAnnotation={onDeleteAnnotation}
          />
        ) : null}
        {tab === "notes" ? (
          <label className="field tall">
            <span>Notes</span>
            <textarea value={draft.notes ?? ""} onChange={(event) => setDraft({ ...draft, notes: event.target.value })} />
          </label>
        ) : null}
        {tab === "cite" ? (
          <CitationPanel reference={draft} citationStyle={citationStyle} onStyle={setCitationStyle} />
        ) : null}
        {tab === "properties" ? (
          <PropertiesPanel
            properties={customProperties}
            values={propertyValues}
            onValues={setPropertyValues}
            onAddProperty={onAddProperty}
          />
        ) : null}
      </div>
      <div className="detail-actions">
        <button type="button" className="text-button primary" onClick={() => onSave(draft, tagsText, propertyValues)}>
          <Check size={16} />
          Save
        </button>
      </div>
    </aside>
  );
}

function DetailsForm({
  draft,
  tagsText,
  onDraft,
  onTagsText
}: {
  draft: ReferenceRecord;
  tagsText: string;
  onDraft: (draft: ReferenceRecord) => void;
  onTagsText: (value: string) => void;
}) {
  return (
    <div className="form-grid">
      <label className="field wide">
        <span>Title</span>
        <input value={draft.title} onChange={(event) => onDraft({ ...draft, title: event.target.value })} />
      </label>
      <label className="field wide">
        <span>Authors</span>
        <input
          value={authorDisplay(draft.authors)}
          onChange={(event) => onDraft({ ...draft, authors: parseAuthors(event.target.value) })}
        />
      </label>
      <label className="field">
        <span>Year</span>
        <input
          type="number"
          value={draft.year ?? ""}
          onChange={(event) => onDraft({ ...draft, year: event.target.value ? Number(event.target.value) : undefined })}
        />
      </label>
      <label className="field">
        <span>Status</span>
        <select value={draft.readingStatus} onChange={(event) => onDraft({ ...draft, readingStatus: event.target.value })}>
          {[...new Set([...readingStatuses, draft.readingStatus])].map((status) => (
            <option key={status} value={status}>
              {status}
            </option>
          ))}
        </select>
      </label>
      <label className="field">
        <span>Type</span>
        <select value={draft.referenceType} onChange={(event) => onDraft({ ...draft, referenceType: event.target.value as ReferenceType })}>
          {referenceTypes.map((type) => (
            <option key={type} value={type}>
              {type}
            </option>
          ))}
        </select>
      </label>
      <label className="field">
        <span>Journal</span>
        <input value={draft.journal ?? ""} onChange={(event) => onDraft({ ...draft, journal: optional(event.target.value) })} />
      </label>
      <label className="field">
        <span>Volume</span>
        <input value={draft.volume ?? ""} onChange={(event) => onDraft({ ...draft, volume: optional(event.target.value) })} />
      </label>
      <label className="field">
        <span>Issue</span>
        <input value={draft.issue ?? ""} onChange={(event) => onDraft({ ...draft, issue: optional(event.target.value) })} />
      </label>
      <label className="field">
        <span>Pages</span>
        <input value={draft.pages ?? ""} onChange={(event) => onDraft({ ...draft, pages: optional(event.target.value) })} />
      </label>
      <label className="field wide">
        <span>DOI</span>
        <input value={draft.doi ?? ""} onChange={(event) => onDraft({ ...draft, doi: optional(event.target.value) })} />
      </label>
      <label className="field wide">
        <span>URL</span>
        <input value={draft.url ?? ""} onChange={(event) => onDraft({ ...draft, url: optional(event.target.value) })} />
      </label>
      <label className="field wide">
        <span>Tags</span>
        <input value={tagsText} onChange={(event) => onTagsText(event.target.value)} />
      </label>
      <label className="field tall wide">
        <span>Abstract</span>
        <textarea value={draft.abstract ?? ""} onChange={(event) => onDraft({ ...draft, abstract: optional(event.target.value) })} />
      </label>
    </div>
  );
}

function ReaderPanel({
  item,
  onAttachPDF,
  onMarkRead,
  onPutAnnotation,
  onDeleteAnnotation
}: {
  item: MaterializedReference;
  onAttachPDF: (referenceId: string, file: File) => void;
  onMarkRead: (reference: ReferenceRecord) => void;
  onPutAnnotation: (annotation: AnnotationRecord) => void;
  onDeleteAnnotation: (annotation: AnnotationRecord) => void;
}) {
  const [annotationType, setAnnotationType] = useState<AnnotationType>("highlight");
  const [annotationText, setAnnotationText] = useState("");
  const [annotationNote, setAnnotationNote] = useState("");
  const [page, setPage] = useState("");

  function addAnnotation() {
    const text = annotationText.trim();
    if (!text && !annotationNote.trim()) return;
    onPutAnnotation({
      id: id("ann"),
      referenceId: item.reference.id,
      kind: item.pdfFile ? "pdf" : "web",
      type: annotationType,
      selectedText: text,
      anchorText: text,
      noteText: optional(annotationNote),
      color: annotationType === "underline" ? "#34C759" : "#FFDE59",
      pageIndex: page ? Number(page) - 1 : undefined,
      dateCreated: nowISO(),
      dateModified: nowISO()
    });
    setAnnotationText("");
    setAnnotationNote("");
    setPage("");
  }

  return (
    <div className="reader-layout">
      <div className="reader-frame">
        {item.pdfFile ? (
          <PDFReader
            file={item.pdfFile}
            annotations={item.annotations}
            annotationType={annotationType}
            annotationNote={annotationNote}
            onPutAnnotation={(annotation) => {
              onPutAnnotation(annotation);
              setAnnotationNote("");
            }}
            onDeleteAnnotation={onDeleteAnnotation}
          />
        ) : item.reference.webContent ? (
          <StoredContentReader reference={item.reference} />
        ) : item.reference.url ? (
          <WebPreview url={item.reference.url} />
        ) : (
          <div className="reader-empty">No reader source</div>
        )}
      </div>
      <div className="reader-tools">
        <div className="reader-actions">
          <label className="text-button file-button">
            <Upload size={15} />
            PDF
            <input
              type="file"
              accept="application/pdf,.pdf"
              onChange={(event) => {
                const file = event.target.files?.[0];
                event.target.value = "";
                if (file) onAttachPDF(item.reference.id, file);
              }}
            />
          </label>
          {item.reference.url ? (
            <a className="text-button" href={item.reference.url} target="_blank" rel="noreferrer">
              <Globe size={15} />
              Open
            </a>
          ) : null}
          <button type="button" className="text-button" onClick={() => onMarkRead(item.reference)}>
            <Check size={15} />
            Read
          </button>
          {item.reference.webContent ? (
            <button
              type="button"
              className="text-button"
              onClick={() => setAnnotationText(window.getSelection()?.toString().trim() ?? "")}
            >
              <Highlighter size={15} />
              Use selection
            </button>
          ) : null}
        </div>
        <div className="annotation-form">
          <select value={annotationType} onChange={(event) => setAnnotationType(event.target.value as AnnotationType)}>
            <option value="highlight">Highlight</option>
            <option value="underline">Underline</option>
            <option value="note">Note</option>
          </select>
          <input value={page} onChange={(event) => setPage(event.target.value)} placeholder="Page" />
          <textarea value={annotationText} onChange={(event) => setAnnotationText(event.target.value)} placeholder="Selected text or anchor" />
          <textarea value={annotationNote} onChange={(event) => setAnnotationNote(event.target.value)} placeholder="Note" />
          <button type="button" className="text-button primary" onClick={addAnnotation}>
            <Plus size={15} />
            Annotation
          </button>
        </div>
        <div className="annotation-list">
          {item.annotations.map((annotation) => (
            <div key={annotation.id} className="annotation-item">
              <span className="annotation-dot" style={{ background: annotation.color }} />
              <div>
                <strong>{annotation.type}</strong>
                <p>{annotation.selectedText || annotation.anchorText || annotation.noteText}</p>
                {annotation.noteText ? <small>{annotation.noteText}</small> : null}
              </div>
              <button type="button" className="icon-button" title="Delete annotation" onClick={() => onDeleteAnnotation(annotation)}>
                <Trash2 size={14} />
              </button>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function PDFReader({
  file,
  annotations,
  annotationType,
  annotationNote,
  onPutAnnotation,
  onDeleteAnnotation
}: {
  file: StoredFileRecord;
  annotations: AnnotationRecord[];
  annotationType: AnnotationType;
  annotationNote: string;
  onPutAnnotation: (annotation: AnnotationRecord) => void;
  onDeleteAnnotation: (annotation: AnnotationRecord) => void;
}) {
  const [url, setUrl] = useState<string>();
  const [pages, setPages] = useState<Array<{ pageNumber: number; text: string }>>([]);
  const [query, setQuery] = useState("");
  const [selectedPage, setSelectedPage] = useState(1);
  const [pageCount, setPageCount] = useState(1);
  const [pageSize, setPageSize] = useState({ width: 0, height: 0 });
  const [indexing, setIndexing] = useState(false);
  const [rendering, setRendering] = useState(false);
  const [error, setError] = useState<string | undefined>();
  const [dragStart, setDragStart] = useState<{ x: number; y: number } | undefined>();
  const [dragCurrent, setDragCurrent] = useState<{ x: number; y: number } | undefined>();
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const next = URL.createObjectURL(file.blob);
    setUrl(next);
    return () => URL.revokeObjectURL(next);
  }, [file.id]);

  useEffect(() => {
    let cancelled = false;
    async function renderPage() {
      if (!canvasRef.current) return;
      setRendering(true);
      setError(undefined);
      try {
        const { renderPDFPage } = await import("./lib/pdfRender");
        const rendered = await renderPDFPage(file.blob, selectedPage, canvasRef.current);
        if (cancelled) return;
        setSelectedPage(rendered.pageNumber);
        setPageCount(rendered.pageCount);
        setPageSize({ width: rendered.width, height: rendered.height });
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setRendering(false);
      }
    }
    renderPage();
    return () => {
      cancelled = true;
    };
  }, [file.id, selectedPage]);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setError(undefined);
      const cached = await getPDFTextPages(file.id);
      if (cancelled) return;
      setPages(cached);
      if (cached.length === 0) {
        await indexPDF();
      }
    }
    load().catch((err: unknown) => {
      if (!cancelled) setError(err instanceof Error ? err.message : String(err));
    });
    return () => {
      cancelled = true;
    };
  }, [file.id]);

  async function indexPDF() {
    setIndexing(true);
    setError(undefined);
    try {
      const { extractPDFText } = await import("./lib/pdfText");
      const extracted = await extractPDFText(file.blob);
      await replacePDFTextPages(file.referenceId, file.id, extracted);
      setPages(extracted);
      setSelectedPage(extracted[0]?.pageNumber ?? 1);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setIndexing(false);
    }
  }

  const matches = useMemo(() => searchPDFText(pages, query), [pages, query]);
  const selectedText = pages.find((page) => page.pageNumber === selectedPage)?.text ?? "";
  const pageAnnotations = annotations.filter(
    (annotation) => annotation.kind === "pdf" && annotation.pageIndex === selectedPage - 1 && annotation.rects?.length
  );
  const dragRect =
    dragStart && dragCurrent && pageSize.width > 0
      ? normalizedRectFromPoints(dragStart, dragCurrent, pageSize)
      : undefined;

  function pointerPoint(event: PointerEvent<HTMLDivElement>): { x: number; y: number } {
    const rect = event.currentTarget.getBoundingClientRect();
    return {
      x: event.clientX - rect.left,
      y: event.clientY - rect.top
    };
  }

  function startDrag(event: PointerEvent<HTMLDivElement>) {
    if (rendering || pageSize.width <= 0) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    const point = pointerPoint(event);
    setDragStart(point);
    setDragCurrent(point);
  }

  function updateDrag(event: PointerEvent<HTMLDivElement>) {
    if (!dragStart) return;
    setDragCurrent(pointerPoint(event));
  }

  function finishDrag(event: PointerEvent<HTMLDivElement>) {
    if (!dragStart) return;
    const rect = normalizedRectFromPoints(dragStart, pointerPoint(event), pageSize);
    setDragStart(undefined);
    setDragCurrent(undefined);
    if (!rect) return;
    onPutAnnotation({
      id: id("ann"),
      referenceId: file.referenceId,
      kind: "pdf",
      type: annotationType,
      selectedText: selectedText.slice(0, 240) || undefined,
      noteText: optional(annotationNote),
      color: annotationType === "underline" ? "#34C759" : annotationType === "note" ? "#5AC8FA" : "#FFDE59",
      pageIndex: selectedPage - 1,
      rects: [rect],
      dateCreated: nowISO(),
      dateModified: nowISO()
    });
  }

  if (!url) return null;
  return (
    <div className="pdf-reader">
      <div className="pdf-canvas-scroll">
        <div
          className="pdf-page-stage"
          style={{ width: pageSize.width || undefined, height: pageSize.height || undefined }}
          onPointerDown={startDrag}
          onPointerMove={updateDrag}
          onPointerUp={finishDrag}
          onPointerCancel={() => {
            setDragStart(undefined);
            setDragCurrent(undefined);
          }}
        >
          <canvas ref={canvasRef} aria-label={`${file.name} page ${selectedPage}`} />
          {pageAnnotations.map((annotation) =>
            annotation.rects?.map((rect, index) => (
              <button
                key={`${annotation.id}-${index}`}
                type="button"
                className={`pdf-annotation-rect ${annotation.type}`}
                style={rectToPercentStyle(rect)}
                title={annotation.noteText || annotation.selectedText || annotation.type}
                onClick={(event) => {
                  event.stopPropagation();
                  if (window.confirm("Delete this annotation?")) onDeleteAnnotation(annotation);
                }}
              />
            ))
          )}
          {dragRect ? <span className={`pdf-annotation-rect draft ${annotationType}`} style={rectToPercentStyle(dragRect)} /> : null}
          {rendering ? <div className="pdf-rendering"><Loader2 className="spin" size={18} /></div> : null}
        </div>
      </div>
      <aside className="pdf-text-panel">
        <div className="pdf-text-header">
          <strong>{file.name}</strong>
          <button type="button" className="icon-button" title="Re-index PDF text" onClick={indexPDF} disabled={indexing}>
            {indexing ? <Loader2 className="spin" size={14} /> : <RefreshCw size={14} />}
          </button>
        </div>
        <div className="pdf-page-controls">
          <button type="button" className="icon-button" title="Previous page" onClick={() => setSelectedPage((page) => Math.max(1, page - 1))}>
            -
          </button>
          <span>
            Page {selectedPage} / {pageCount}
          </span>
          <button type="button" className="icon-button" title="Next page" onClick={() => setSelectedPage((page) => Math.min(pageCount, page + 1))}>
            +
          </button>
        </div>
        <p className="pdf-annotation-help">Drag on the rendered page to save a {annotationType} rectangle.</p>
        <label className="field">
          <span>Search PDF text</span>
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={indexing ? "Indexing..." : "Search extracted text"} />
        </label>
        {error ? <div className="pdf-text-error">{error}</div> : null}
        <div className="pdf-match-list">
          {query.trim() ? (
            matches.length ? (
              matches.map((match, index) => (
                <button key={`${match.pageNumber}-${match.index}-${index}`} type="button" onClick={() => setSelectedPage(match.pageNumber)}>
                  <span>Page {match.pageNumber}</span>
                  <small>{match.snippet}</small>
                </button>
              ))
            ) : (
              <p>{pages.length ? "No matches" : "No extracted text yet"}</p>
            )
          ) : (
            pages.map((page) => (
              <button key={page.pageNumber} type="button" onClick={() => setSelectedPage(page.pageNumber)} className={page.pageNumber === selectedPage ? "selected" : ""}>
                <span>Page {page.pageNumber}</span>
                <small>{page.text.slice(0, 180) || "No text extracted from this page"}</small>
              </button>
            ))
          )}
        </div>
        {selectedText ? <p className="pdf-selected-text">{selectedText.slice(0, 700)}</p> : null}
      </aside>
    </div>
  );
}

function StoredContentReader({ reference }: { reference: ReferenceRecord }) {
  const html = useMemo(() => renderStoredContent(reference), [reference.webContent, reference.webContentFormat]);
  return <article className="stored-content" dangerouslySetInnerHTML={{ __html: html }} />;
}

function WebPreview({ url }: { url: string }) {
  return (
    <div className="web-preview">
      <Globe size={22} />
      <a href={url} target="_blank" rel="noreferrer">
        {url}
      </a>
    </div>
  );
}

function CitationPanel({
  reference,
  citationStyle,
  onStyle
}: {
  reference: ReferenceRecord;
  citationStyle: CitationStyle;
  onStyle: (style: CitationStyle) => void;
}) {
  const inline = formatInlineCitation([reference], citationStyle);
  const bibliography = formatBibliography(reference, citationStyle);
  return (
    <div className="citation-panel">
      <label className="field">
        <span>Style</span>
        <select value={citationStyle} onChange={(event) => onStyle(event.target.value as CitationStyle)}>
          {supportedCitationStyles.map((style) => (
            <option key={style} value={style}>
              {style.toUpperCase()}
            </option>
          ))}
        </select>
      </label>
      <CopyBlock label="Inline" value={inline} />
      <CopyBlock label="Bibliography" value={bibliography} />
    </div>
  );
}

function CopyBlock({ label, value }: { label: string; value: string }) {
  return (
    <div className="copy-block">
      <div>
        <strong>{label}</strong>
        <p>{value}</p>
      </div>
      <button type="button" className="icon-button" title="Copy" onClick={() => navigator.clipboard.writeText(value)}>
        <Check size={15} />
      </button>
    </div>
  );
}

function PropertiesPanel({
  properties,
  values,
  onValues,
  onAddProperty
}: {
  properties: PropertyDefinitionRecord[];
  values: Record<string, string>;
  onValues: (values: Record<string, string>) => void;
  onAddProperty: (name: string, type: PropertyType, optionsText: string) => void;
}) {
  const [name, setName] = useState("");
  const [type, setType] = useState<PropertyType>("string");
  const [optionsText, setOptionsText] = useState("");

  function addProperty() {
    onAddProperty(name, type, optionsText);
    setName("");
    setType("string");
    setOptionsText("");
  }

  return (
    <div className="properties-panel">
      <div className="property-creator">
        <label className="field">
          <span>Name</span>
          <input value={name} onChange={(event) => setName(event.target.value)} placeholder="Property name" />
        </label>
        <label className="field">
          <span>Type</span>
          <select value={type} onChange={(event) => setType(event.target.value as PropertyType)}>
            <option value="string">Text</option>
            <option value="url">URL</option>
            <option value="number">Number</option>
            <option value="singleSelect">Select</option>
            <option value="multiSelect">Multi-select</option>
            <option value="date">Date</option>
            <option value="checkbox">Checkbox</option>
          </select>
        </label>
        {type === "singleSelect" || type === "multiSelect" ? (
          <label className="field wide">
            <span>Options</span>
            <input value={optionsText} onChange={(event) => setOptionsText(event.target.value)} placeholder="Option A, Option B" />
          </label>
        ) : null}
        <button type="button" className="text-button" onClick={addProperty} disabled={!name.trim()}>
          <Plus size={15} />
          Property
        </button>
      </div>
      {properties.map((property) => (
        <PropertyValueControl
          key={property.id}
          property={property}
          value={values[property.id] ?? ""}
          onChange={(value) => onValues({ ...values, [property.id]: value })}
        />
      ))}
    </div>
  );
}

function PropertyValueControl({
  property,
  value,
  onChange
}: {
  property: PropertyDefinitionRecord;
  value: string;
  onChange: (value: string) => void;
}) {
  if (property.type === "checkbox") {
    return (
      <label className="field inline-field">
        <span>{property.name}</span>
        <input type="checkbox" checked={value === "true"} onChange={(event) => onChange(event.target.checked ? "true" : "false")} />
      </label>
    );
  }

  if (property.type === "singleSelect") {
    return (
      <label className="field">
        <span>{property.name}</span>
        <select value={value} onChange={(event) => onChange(event.target.value)}>
          <option value="">None</option>
          {property.options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.value}
            </option>
          ))}
        </select>
      </label>
    );
  }

  if (property.type === "multiSelect") {
    const selected = new Set(value.split(",").map((item) => item.trim()).filter(Boolean));
    return (
      <fieldset className="property-multiselect">
        <legend>{property.name}</legend>
        {property.options.map((option) => (
          <label key={option.value} className="inline-check">
            <input
              type="checkbox"
              checked={selected.has(option.value)}
              onChange={(event) => {
                const next = new Set(selected);
                if (event.target.checked) next.add(option.value);
                else next.delete(option.value);
                onChange([...next].join(", "));
              }}
            />
            <span className="option-dot" style={{ background: option.color }} />
            {option.value}
          </label>
        ))}
      </fieldset>
    );
  }

  const inputType = property.type === "number" ? "number" : property.type === "date" ? "date" : property.type === "url" ? "url" : "text";
  return (
    <label className="field">
      <span>{property.name}</span>
      <input type={inputType} value={value} onChange={(event) => onChange(event.target.value)} />
    </label>
  );
}

function renderCell(item: MaterializedReference, column: ColumnIdentifier) {
  if (column === "title") {
    return (
      <div className="title-cell">
        <strong>{item.reference.title || "Untitled"}</strong>
        {item.reference.abstract ? <span>{item.reference.abstract}</span> : null}
      </div>
    );
  }
  if (column === "tags") {
    return (
      <div className="chip-row">
        {item.tags.map((tag) => (
          <span key={tag.id} className="pill" style={{ borderColor: tag.color }}>
            {tag.name}
          </span>
        ))}
      </div>
    );
  }
  if (column === "readingStatus") return <span className="status-pill">{item.reference.readingStatus}</span>;
  if (column === "pdfAttached") return item.pdfFile ? <FileText size={16} /> : "";
  if (column === "authors") return authorDisplay(item.reference.authors);
  return displayField(item, { kind: "builtin", value: column });
}

function optional(value: string): string | undefined {
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}

function downloadText(content: string, name: string, type: string) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = name;
  anchor.click();
  URL.revokeObjectURL(url);
}
