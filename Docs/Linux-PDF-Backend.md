# Linux PDF backend (RubienPDFKit / Poppler)

How the Linux side of `RubienPDFKit` is wired up, and the load-bearing facts about poppler-glib / gdk-pixbuf / cairo / Swift C-interop that informed the design. Read this before touching `Sources/RubienPDFKit/Linux/`.

## Why a facade

The Mac app uses Apple's PDFKit. PDFKit doesn't exist on Linux, but `RubienCore` and `rubien-cli` must build there for CI (and for any future Linux consumer of the library). The `PDFDocumentProtocol` / `PDFPageProtocol` facade in `Sources/RubienPDFKit/PDFFacadeTypes.swift` is the single abstraction; `Sources/RubienPDFKit/Darwin/` wraps PDFKit and `Sources/RubienPDFKit/Linux/` wraps poppler-glib + cairo + gdk-pixbuf.

`PDFBackend.open(url:)` dispatches at compile time (`#if canImport(PDFKit)` → Darwin, `#elseif os(Linux)` → Linux). Callers (`PDFExtractor`, `PDFService`) only see the facade.

## System dependencies on Linux

Required apt packages (CI installs these in `.github/workflows/ci.yml`):

```
libpoppler-glib-dev   # poppler-glib 22.02+ — PDF document/page/outline/render
libcairo2-dev         # cairo image surfaces for the render target
libgdk-pixbuf-2.0-dev # PNG/JPEG encoding of the rendered raster
pkg-config            # SPM systemLibrary discovery
```

SPM wiring is in `Package.swift` — two `.systemLibrary` targets (`CPoppler`, `CGdkPixbuf`) declare `pkgConfig` and apt providers. The `RubienPDFKit` target conditionally depends on both on `.linux`.

## Load-bearing API facts

These were discovered the hard way during Docker iteration. Don't re-litigate them.

### 1. `gdk_pixbuf_get_from_surface` was removed from standalone gdk-pixbuf

It used to live in `gdk-pixbuf/gdk-pixbuf-core.h` but was moved into GTK proper around the 2.42 line. **Don't try to use it.** We do the cairo → pixbuf conversion ourselves in `LinuxPDFPage.encodeCairoSurface`:

1. Read the cairo image surface bytes via `cairo_image_surface_get_data` + `_get_stride`.
2. Per-pixel rearrange from cairo's `CAIRO_FORMAT_RGB24` native-endian layout (low 24 bits R/G/B, top 8 unused → little-endian in-memory byte order is `B G R X`) into gdk-pixbuf's 24-bit packed RGB.
3. Hand the converted buffer to `gdk_pixbuf_new_from_data` with a destroy callback so the pixbuf owns the lifetime.

Big-endian Linux targets are not in scope. The conversion would need to flip `srcPx[0/1/2]` if we ever ship there.

### 2. Cairo stride may exceed `width × bytes_per_pixel`

Always read it via `cairo_image_surface_get_stride(surface)`. The conversion loop increments `srcRow` by `stride` and `dstRow` by `width × 3` independently.

### 3. Swift C-interop: opaque pointer rule

- C struct **forward-declared only** (`typedef struct _Foo Foo;` with no body in any header Swift sees) → Swift imports `Foo *` as `OpaquePointer`.
- C struct **fully defined** (body visible) → Swift imports `Foo *` as `UnsafeMutablePointer<Foo>` with accessible `.pointee.fieldName`.

Applied here:

| C type | Definition site | Swift import |
|---|---|---|
| `PopplerDocument`, `PopplerPage`, `PopplerIndexIter`, `PopplerAction *` (the union pointer return from `_get_action`), `GdkPixbuf` | forward-declared (definitions in C++ sources) | `OpaquePointer` |
| `GError` | full struct in `<glib.h>` | `UnsafeMutablePointer<GError>` |
| `PopplerDest` (returned by-pointer) | full struct in `<poppler-action.h>` | `UnsafeMutablePointer<PopplerDest>` |
| `PopplerActionGotoDest` / `_Any` / `_Uri` etc. (accessed as union members) | full struct in `<poppler-action.h>` | Swift struct, accessible via `.pointee.goto_dest`, `.pointee.any`, … |

`GObjectBox` stores `OpaquePointer` (not a typed generic) because all GObject types we wrap are opaque-pointer-imported.

**Don't wrap `OpaquePointer` values in `OpaquePointer(...)` again.** `OpaquePointer.init` accepts `UnsafeMutableRawPointer` and `UnsafeRawPointer` and the typed `UnsafeMutablePointer<T>` family, but not `OpaquePointer` itself. The compiler error reads "no exact matches in call to initializer" — that's this.

### 4. Poppler outline iteration

The pinned signatures from `<poppler/glib/poppler-document.h>` + `poppler-action.h`:

```c
PopplerIndexIter *poppler_index_iter_new(PopplerDocument *document);
    // → root iter at first top-level entry, or NULL if no outline.
    //   Free with poppler_index_iter_free.

PopplerIndexIter *poppler_index_iter_get_child(PopplerIndexIter *parent);
    // → child iter at first child, or NULL. Free with poppler_index_iter_free.

gboolean poppler_index_iter_next(PopplerIndexIter *iter);
    // Advances iter to next sibling in place. FALSE = no more siblings.

PopplerAction *poppler_index_iter_get_action(PopplerIndexIter *iter);
    // → newly-allocated action. Free with poppler_action_free
    //   (NOT g_free — actions own their internal strings).

void poppler_index_iter_free(PopplerIndexIter *iter);
```

**Iteration shape**: `poppler_index_iter_new` returns the iter at the FIRST top-level item, not a parent container. The Swift walker is a do-while: read the current iter's action, recurse on `get_child` if any, then `next` to advance to the sibling. See `LinuxPDFDocument.walkOutline`.

### 5. PopplerAction tagged union

Every variant starts with `PopplerActionAny { type, title }`. Switch on `action.pointee.type` (which is `PopplerActionType`), then access the matching union member by name:

| `type` value | Member access | Useful field |
|---|---|---|
| `POPPLER_ACTION_GOTO_DEST` | `action.pointee.goto_dest` | `title: gchar*`, `dest: UnsafeMutablePointer<PopplerDest>?` |
| `POPPLER_ACTION_URI` | `action.pointee.uri` | `title`, `uri: char*` |
| anything else | `action.pointee.any` | `title` |

For outline entries we care about `GOTO_DEST` (page-targeting) and `URI` / `NAMED` etc. (preserve label, set `pageIndex = nil`).

### 6. PopplerDest layout + 1-based page numbers

```c
struct _PopplerDest {
    PopplerDestType type;       // POPPLER_DEST_XYZ / FIT / NAMED / UNKNOWN / ...
    int page_num;               // 1-based per PDF spec
    double left, bottom, right, top, zoom;
    gchar *named_dest;          // valid only when type == POPPLER_DEST_NAMED
    guint change_left : 1, change_top : 1, change_zoom : 1;
};
```

Convert poppler's 1-based `page_num` to the facade's 0-based `PDFOutlineNode.pageIndex` by subtracting 1. For `POPPLER_DEST_NAMED`, resolve via `poppler_document_find_dest(doc, named_dest)` → newly-allocated `PopplerDest *` that you must free with `poppler_dest_free`.

### 7. POPPLER_ERROR_ENCRYPTED → `.locked`

The `PopplerError` enum is:

```
0 POPPLER_ERROR_INVALID
1 POPPLER_ERROR_ENCRYPTED
2 POPPLER_ERROR_OPEN_FILE
3 POPPLER_ERROR_BAD_CATALOG
4 POPPLER_ERROR_DAMAGED
```

In `LinuxPDFDocument.init`: if `poppler_document_new_from_file` returns NULL and the GError's `.code == POPPLER_ERROR_ENCRYPTED.rawValue`, throw `PDFOpenError.locked`. Any other code maps to `.cannotOpen`. The cross-backend parity test for password-protected PDFs depends on this mapping.

### 8. gdk-pixbuf `save_to_bufferv` knobs

JPEG quality is passed as the option key `"quality"` with value `"0"`–`"100"` (string). PNG accepts a `"compression"` key (`"0"`–`"9"`) but we don't use it — the renderer passes `nil` for option arrays in the PNG path.

Caller owns the output buffer — free with `g_free`. Wrap in Swift `Data` via `Data(bytesNoCopy:count:deallocator: .custom { ptr, _ in g_free(ptr) })`.

### 9. GObject reference counting

`poppler_document_new_from_file`, `poppler_document_get_page`, `gdk_pixbuf_new_from_data` all return a `+1` ref. `GObjectBox.init(takingOwnershipOf:)` takes that ref over; `deinit` runs `g_object_unref`. **Do not pre-ref** before constructing the box.

`g_object_unref` takes `gpointer` (= `UnsafeMutableRawPointer?` in Swift). Convert from `OpaquePointer` with `UnsafeMutableRawPointer(opaquePtr)`. The reverse conversion does not exist (`OpaquePointer(opaquePtr)` is the compile error described in §3).

## Tests: per-test isolation on Linux

`Tests/RubienPDFKitTests/BackendParityTests.swift` runs cleanly in one process on macOS — Xcode's XCTest handles 12 tests in ~0.1s.

On Linux, swift-corelibs-xctest runs the whole bundle in a single process and uses libdispatch (GCD) to sequence test methods. After any test touches the threaded C libraries we link (poppler-glib, cairo, gdk-pixbuf each spin up internal worker threads), GCD's worker pool occasionally gets into a state where the next test method never gets dispatched — the xctest process sits forever on `do_sys_poll` + `do_epoll_wait`. Repro rate is ~40% with `swift test --filter RubienPDFKitTests` on `swift:6.3-jammy` (both arm64 and amd64); individual `swift test --filter RubienPDFKitTests.BackendParityTests/testFoo` invocations show 0 flakes across hundreds of runs. The hang is in swift-corelibs-xctest's inter-test sequencing, not in the backend itself.

Workaround: `scripts/run-linux-parity-tests.sh` invokes each parity test in its own `swift test --filter` process. CI uses this script on the Linux job. The cost is ~5-10s per test instead of ~0.01s per test, total ~90s vs ~0.1s — fine for CI, awkward for tight local iteration.

If you find the hang reproducing for you locally:

```bash
# This will sometimes hang:
swift test --filter RubienPDFKitTests

# This always passes:
./scripts/run-linux-parity-tests.sh
```

When swift-corelibs-xctest fixes the GCD scheduling (or when we move parity tests off XCTest), the wrapper script can go.

## What's stubbed (follow-up work)

- **`PDFDocumentProtocol.isEncrypted`** returns `false` on Linux. Poppler doesn't expose the "file is encrypted but you have read access" attribute the way PDFKit does — by the time we hold a successfully-opened document, the readable bit is set and the encrypted attribute is hidden. Acceptable mismatch for v1: the locked-PDF parity path is exercised via the `init` failure throwing `.locked`.
- **Big-endian Linux** is not supported. The cairo → pixbuf byte-rearrange assumes little-endian.
- **Big outline performance**: we eagerly materialize the entire outline tree at open time. For PDFs with thousands of bookmarks this is wasteful; a lazy iterator wrapper would help. Not in scope until a real-world PDF triggers it.

## Smoke checklist after touching the Linux backend

```bash
docker run --rm -v "$PWD:/src" -w /src swift:6.3-jammy bash -lc '
  apt-get update >/dev/null &&
  apt-get install -y libsqlite3-dev libpoppler-glib-dev libcairo2-dev libgdk-pixbuf-2.0-dev pkg-config >/dev/null &&
  swift build --product rubien-cli &&
  swift test --filter "RubienCoreTests|RubienCLITests|RubienPDFKitTests"
'
```

The Mac side does NOT exercise this code at all — `os(Linux)` gates it out. Regressions in `LinuxPDFDocument` / `LinuxPDFPage` can only be caught by running through Docker (or by CI's Linux job).
