# Browser Clipper MVP Plan

## Goal

Add a one-click Chrome entry point for Rubien's unified **Import Reference**
flow, including its confirmation-before-save behavior. The current tab must
follow the same routing rules as the app: known
paper URLs resolve bibliographic metadata, direct
PDF/Markdown URLs enter the file import coordinators, and only ordinary pages
become web clips. The motivating web-page case remains an X Article that a
fresh `WKWebView` cannot read because it does not share Chrome's authenticated
session.

The clipper must not read or transfer cookies, tokens, passwords, or browser
storage into Rubien. It transfers metadata and cleaned article HTML extracted
from the DOM the user explicitly chose. For a verified paper, Chrome may use
its own signed-in session to download the trusted publisher PDF URL returned by
Rubien; only the temporary local path is passed to the helper.

## MVP contract

- Manifest V3 extension with `activeTab`, `scripting`, `downloads`, and
  `nativeMessaging` permissions. No persistent all-sites host permission.
- A click (or the extension keyboard shortcut) opens a popup and injects
  Rubien's checked-in Defuddle bundle into the active tab's isolated extension
  world while the popup prepares a preview.
- The extension collects canonical URL, favicon/site metadata, Defuddle's
  cleaned article result, and `citation_*` metadata already present in the
  document.
- A versioned JSON payload is sent to `com.rubien.browser_clipper` through a
  long-lived Chrome Native Messaging port. `preview` stages the routed result
  in that helper process; `confirm` must present its connection-bound ID.
- A small `rubien-browser-host` executable validates the payload and sends the
  tab URL through `AddReferenceInputRouter`, the same classifier used by the
  app's Import Reference sheet.
- Metadata routes use `MetadataFetcher`, normal dedup persistence, and the same
  verification and pending-review behavior as Add by Identifier. File routes use
  `ImportSourceMaterializer`, `PDFImportCoordinator`, or `MarkdownImporter`.
  PDF resolutions that need confirmation enter the existing pending-intake
  queue.
- Verified paper routes surface only a resolver-trusted PDF URL in the preview.
  After confirmation, Chrome downloads it with the publisher cookies already
  in the user's browser; the helper validates, imports, and attaches the PDF,
  then the extension removes the temporary download.
- Website routes preserve the extension's authenticated DOM capture and save a
  `.webpage` reference. Citation metadata is supporting fallback data for a
  paper route; it must not turn an otherwise-generic site into a paper and
  thereby bypass the shared router.
- The popup shows a resolved title/type/metadata preview and warns when Confirm
  will place the item in Rubien's pending-review queue. The database is not
  mutated until Confirm. Cancel, popup close, or native disconnect discards the
  staged import and temporary files.
- A verified paper preview offers a **Download PDF** option that defaults on.
  Turning it off commits metadata only and suppresses both Chrome-authenticated
  and Rubien fallback downloads.
- After confirmation, the popup reports created, existing, queued-for-review,
  or failed. Opening/revealing Rubien is deferred; a running app refreshes
  through `LibraryChangeBroadcaster`.

## Integration shape

1. Add a browser-result callback to the existing Defuddle bridge without
   changing its current `WKScriptMessageHandler` behavior.
2. Extend the clipper build script to copy the generated bundle into the
   extension's ignored `dist/` directory.
3. Add the extension manifest, popup, and service worker under
   `BrowserExtension/`.
   A fixed manifest public key gives unpacked development installs a stable
   extension ID, which is required by Native Messaging's exact
   `allowed_origins` rule.
4. Add `RubienCore` DTOs/constants for the versioned wire contract. These are
   transport values only and do not add a new database mutation API.
5. Add a Swift executable target for message framing and unified import. The
   macOS build links `RubienPDFKit` for direct PDF imports and is embedded and
   signed with the same App Group entitlement as `rubien-cli` in packaged
   builds. Linux retains a portable build path without PDFKit linkage.
6. Add a macOS app-side installer that registers the bundled helper in Chrome's
   per-user `NativeMessagingHosts` directory on launch. `swift run Rubien`
   remains side-effect free when no bundled helper exists.
7. Update `scripts/build-app.sh`, `scripts/dev-launch.sh`, and user/developer
   documentation for building and loading the extension.

## Safety and validation

- Reject non-HTTP(S) page/canonical URLs and unsupported contract versions.
- Enforce bounded message, HTML, metadata, and field sizes before database
  writes.
- Validate `%PDF-` magic before copying any Chrome-downloaded file into Rubien.
- Trust only Chrome's configured extension origin, and validate the caller
  origin again in the helper process.
- Keep stdout exclusively for length-prefixed native-messaging responses;
  diagnostics go to stderr.
- Unit-test request/response decoding, multi-message framing boundaries,
  validation, zero-write previews, connection-bound confirmation, cancellation
  cleanup, paper routing, direct PDF/Markdown routing, queued PDF results,
  URL-only fallback, and duplicate merge behavior against an in-memory
  database.
- Build the extension bundle, run targeted Swift tests, then run the full
  build/test checks required by the repository workflow.

## Deferred

- Chrome Web Store publication and its final store-assigned extension ID.
- Firefox/Safari variants.
- Downloading authenticated images or attachments into Rubien.
- Importing text rendered by Chrome's PDF viewer separately from the PDF file.
- Tags, destination views, or editable preview metadata.
