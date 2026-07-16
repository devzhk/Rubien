# Rubien Web Port

Rubien Web is a browser-local version of the Rubien reference manager. It is
kept separate from the native SwiftPM targets under `web/` so macOS app and CLI
builds stay unchanged.

## Scope

Implemented in the web client:

- Local IndexedDB library for references, tags, custom properties, saved views,
  annotations, and attached PDF blobs.
- Add by DOI, arXiv ID, ISBN, URL, or title through public metadata APIs when
  the browser can reach them.
- Manual add/edit for Rubien reference fields, reading status, reference type,
  tags, notes, and typed custom properties.
- Saved-view search, field filters, status filters, column visibility, sort,
  grouping, and tag scoped views. Filters cover built-in fields and custom
  text, URL, number, select, multi-select, date, and checkbox properties.
- BibTeX, RIS, Markdown, saved HTML, plain-text, and Rubien Web JSON
  import/export.
- Local PDF attachment and in-browser PDF preview.
- Local PDF text extraction, persisted page text, page-scoped PDF search, and
  library-wide search over indexed PDF text.
- pdf.js page rendering with persisted normalized highlight/underline/note
  rectangles drawn over the selected page.
- Stored Markdown/HTML reader content with sanitized in-app rendering.
- Web capture workflow: fetch a URL when the site permits browser access, or
  paste saved page HTML/selection HTML when CORS blocks direct fetching. Captured
  pages run through Mozilla Readability and are stored for offline local reading.
- Web/PDF annotation records with highlight, underline, and note types.
- APA, MLA, Chicago, IEEE, Harvard, Vancouver, and Nature citation formatting.
- PWA packaging: app manifest, install icon, production service worker, and
  offline app-shell caching. User library data remains local in IndexedDB.

Intentionally not included:

- iCloud/CloudKit sync.
- Sparkle updates, signing, notarization, native window behavior, or other
  macOS-only surfaces.
- Native Zotero local import. Use Zotero BibTeX/RIS export and import the file.
- CLI/MCP hosting inside the browser.
- Guaranteed arbitrary URL fetching. Browser CORS blocks many paper pages, so
  direct capture is best-effort and the saved-HTML paste/import path is the
  reliable cross-browser fallback.

## Run

```bash
cd web
npm install
npm run dev
```

Build and tests:

```bash
cd web
npm run test
npm run build
```

Preview the production build:

```bash
cd web
npm run preview
```

In a production build, browsers that support installable web apps can install
Rubien Web from the address bar/browser menu. The app shell is cached for
offline reloads after the first successful load; local library data stays in the
same browser profile's IndexedDB.

The browser library is local to the browser profile. Use Export -> JSON snapshot
to move it between machines or browsers.
