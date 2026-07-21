# Rubien Importer

This Manifest V3 Chrome extension prepares the active tab for Rubien with one click, then shows a confirmation preview before anything is saved. Extraction runs inside the tab's isolated extension world, so it can read content already rendered for the signed-in user without copying cookies, account tokens, or browser storage into Rubien.

Chrome 110 or newer is required. During unusually slow client-side extraction, the service worker makes a lightweight extension API call every 25 seconds so Chrome does not discard the in-flight action.

The checked-in manifest key gives unpacked builds the stable extension ID `pggebflfobimhklmgebcfgeobajkgdbb`. The native host accepts messages only from that exact origin.

## GitHub Release installation

Launch the matching Rubien app once, unzip
`Rubien-Browser-Extension-<version>.zip`, then open `chrome://extensions`,
enable **Developer mode**, choose **Load unpacked**, and select the extracted
`Rubien-Browser-Extension` folder.

## Development setup

From the repository root:

```bash
npm --prefix scripts/clipper ci
npm --prefix scripts/clipper run build
swift build --product rubien-browser-host
node BrowserExtension/install-native-host.mjs
```

Then open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select the `BrowserExtension` directory. Pin **Rubien Importer** and click it on a paper, PDF, Markdown document, or article page. Review Rubien's resolved preview and choose **Confirm import**. The keyboard shortcut is `Command+Shift+R` on macOS.

Ordinary `swift run Rubien` builds and the unsigned development helper both use `~/Library/Application Support/Rubien`. For signed App Group behavior, use `./scripts/dev-launch.sh`; the signed app registers its bundled helper automatically.

Use `node BrowserExtension/install-native-host.mjs --dry-run` to validate the extension ID and helper path without changing Chrome's native-host registration.

## What gets imported

The extension is a browser front door to Rubien's **Import Reference** flow. It
routes the current tab the same way as the app:

- known paper and publisher URLs resolve and verify bibliographic metadata;
- after confirmation, verified papers download their PDF through Chrome so
  publisher-account cookies already present in the browser can be used;
- direct `.pdf` URLs download through Chrome and enter Rubien's PDF
  metadata/import pipeline;
- direct `.md` or `.markdown` URLs download through Chrome and enter the
  Markdown importer;
- other HTTP(S) pages become web references using the authenticated content
  already rendered in Chrome.

For the web-page branch, the extension reuses Rubien's bundled Defuddle
extractor and sends the canonical URL, title, author, excerpt, cleaned article
HTML, favicon, and common citation metadata to the local native host. If script
injection is unavailable (including Chrome's built-in PDF viewer), Rubien still
imports the tab by URL through the appropriate paper/file route.

The popup shows the same resolved title, authors, year, source type, and review
status that Rubien will commit. A paper or PDF that needs metadata review is
clearly marked as going to the pending-review queue. Until **Confirm import** is
pressed, the native helper performs no library writes. Before confirmation,
closing the popup or choosing **Cancel** discards the prepared import and any
temporary download. Once confirmation begins, the extension keeps the file
until the native helper acknowledges that it has finished importing it.
For verified papers, **Download PDF** is enabled by default in the confirmation
preview; clear it to import bibliographic metadata without downloading a PDF.

After confirmation, the popup reports whether the reference was created,
matched an existing item, or entered the pending-review queue, plus whether a
paper PDF was attached. Choose **Open in Rubien** to reveal a created or matched
reference in the library; queued imports open directly in the pending-review
sheet.

## Security and packaging

The extension requests `activeTab`, `scripting`, `downloads`, and
`nativeMessaging`. It has no persistent host permissions and sends no cookies
or credentials to Rubien. For a verified paper, Chrome's downloads API fetches
only the trusted PDF URL selected by Rubien's known-publisher resolver; direct
PDF and Markdown imports fetch only the active tab URL the user selected.
Chrome includes the site cookies it already owns. The helper validates the
token-bound temporary path and file type, copies it into Rubien, and the
extension removes the temporary download and its history entry. Page content
and the temporary file path are passed locally over a connection-bound,
versioned, and size-limited native-messaging contract.
Preview and confirmation must occur on the same native connection, so a stale
or replayed confirmation cannot commit an abandoned import.

`dist/ClipperDefuddle.js` is generated and ignored. Rebuild it with `npm --prefix scripts/clipper run build`; do not edit it by hand.

The app packaging script embeds and signs `rubien-browser-host` beside `rubien-cli`, including its release dSYM. Chrome Web Store publication is intentionally deferred. If a store build receives a different extension ID, add that exact origin to both the Swift contract and the generated native-host manifest before release.
