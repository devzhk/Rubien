# OpenReview browser PDF import

The signed-in browser can display OpenReview `/pdf?id=…` URLs while native
metadata requests receive a verification challenge. Import one paper with its
authenticated PDF and official forum citation metadata, without saving a web
clip or depending on a native forum-page fetch.

1. Recognize OpenReview PDF and forum tabs in Chrome download staging. Forum
   URLs map to the PDF endpoint using the same paper ID. Read only the forum's
   rendered `citation_*` metadata because an authenticated browser can access
   it even when Rubien's direct request is challenged. For a selected PDF tab,
   open the corresponding forum in a background tab long enough to collect the
   same structured metadata, then close it.
2. Accept their token-bound PDF downloads in the native host and route them to
   PDF preparation. Retain file validation, preview/confirmation, and cleanup.
3. Treat a complete OpenReview citation (title plus authors) as the metadata the
   user confirms in the extension preview. Persist it as manually verified,
   attach the PDF, and discard any forum article HTML. Incomplete capture keeps
   the existing safe PDF-review fallback.
4. Cover authenticated staging from both URL forms, background-tab cleanup,
   routing without publisher resolution, invalid downloads, direct save, PDF
   attachment, and the absence of captured web content.
5. Update browser import documentation; build and run focused tests.

Scope: browser imports only. No changes to CLI contracts, shared URL routing,
schema, dependencies, releases, or installed host registration.

The initial forum/PDF fix passed its focused checks. Candidate smoke tests then
showed two product issues: direct PDF tabs lacked the forum metadata and queued
review, while forum tabs also saved a web article. The revised implementation
uses the forum only as a structured metadata source and produces one PDF-backed
paper from either URL form.

The prior independent review found that queued PDF imports could lose the
selected OpenReview URL; the final verified reference preserves it. The revised
implementation passed `swift build --disable-automatic-resolution`, all 44
`RubienBrowserHostTests`, and all 23 extension Node tests. Independent review
found one late-populated metadata edge case; the waiter now observes `content`
attribute updates and its regression test passes. The reviewer confirmed the
fix with no remaining actionable findings. The optional `/simplify` sweep was
not requested.
