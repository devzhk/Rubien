# Rubien Importer Privacy Policy

*Effective September 4, 2026*

Rubien Importer is the browser companion for Rubien, a native macOS research
library and reference manager. This policy explains how the extension handles
information when you ask it to preview and import the current browser tab.

## Information handled

Rubien Importer accesses a tab only after you click the extension or use its
keyboard shortcut. For that selected tab, it may process the page URL, title,
favicon, author, description, citation metadata, and readable page content. If
you choose to import a PDF or Markdown document, it may also handle the selected
file and its temporary local path.

This information can include website content and browsing activity for the page
you explicitly selected. The extension does not monitor other tabs or browsing
activity in the background.

## How the information is used

The selected information is used only to:

- prepare the import preview you requested;
- resolve and verify bibliographic metadata;
- download a selected paper, PDF, or Markdown document; and
- save the reference you confirm into your Rubien library.

The extension sends the preview and confirmed import to the Rubien app on the
same computer through Chrome native messaging. Rubien may contact public
scholarly metadata services, such as Crossref, arXiv, PubMed, Open Library,
OpenAlex, and Semantic Scholar, to resolve or verify publication information.
Those services receive only the identifiers, titles, or other citation details
needed for that lookup and apply their own privacy policies.

## Downloads and authentication

When you request a PDF or Markdown import, Chrome may download the active URL or
a verified publisher PDF URL. Chrome can use the publisher session already
present in your browser, but Rubien Importer does not read, copy, or send your
cookies, passwords, authentication tokens, or form data to Rubien or the
developer.

Temporary downloads are removed after the import is completed or cancelled
whenever Chrome permits, and their download-history entries are erased. The
extension does not use Chrome storage to retain page content or maintain a
browsing history.

## Storage and optional iCloud sync

Confirmed references are stored by the Rubien app in your local Rubien library
until you delete them. If you separately enable iCloud sync in Rubien, the app
syncs eligible library data through your Apple iCloud account using CloudKit.
Rubien Importer does not operate an independent cloud storage service.

## Sharing, sale, and advertising

Rubien Importer has no advertising or analytics SDKs. The developer does not
sell user data or use it for advertising, credit decisions, or any purpose
unrelated to the user-requested import. Information is not shared with third
parties except for the local transfer to Rubien, the selected download request,
the optional Apple iCloud sync you enable, and the metadata lookups described
above.

## Your control

Nothing is saved before Rubien shows an import preview and you choose **Confirm
import**. Closing the popup or choosing **Cancel** discards the prepared import.
You can delete a confirmed reference and its attached content from Rubien at any
time.

## Chrome Web Store Limited Use

Rubien Importer's use of information received from Chrome APIs complies with
the Chrome Web Store User Data Policy, including the Limited Use requirements.

## Changes and contact

Material changes to this policy will be posted on this page with an updated
effective date. For privacy questions, open an issue in the
[Rubien support tracker](https://github.com/devzhk/Rubien/issues).
