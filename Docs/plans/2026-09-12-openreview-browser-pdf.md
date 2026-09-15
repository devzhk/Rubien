# OpenReview browser PDF import

The signed-in browser can display OpenReview `/pdf?id=…` URLs while native
metadata requests receive a verification challenge. Import the browser download
through the existing PDF pipeline without depending on a forum-page fetch.

1. Recognize OpenReview PDF and forum tabs in Chrome download staging. Forum
   URLs map to the PDF endpoint using the same paper ID, without needing a
   native request or successful DOM extraction.
2. Accept their token-bound PDF downloads in the native host and route them to
   PDF preparation. Retain file validation, preview/confirmation, and cleanup.
3. Cover authenticated staging, routing without publisher resolution, invalid
   downloads, and preservation of a PDF when metadata needs review.
4. Update browser import documentation; build and run focused tests.

Scope: browser imports only. No changes to CLI contracts, shared URL routing,
schema, dependencies, releases, or installed host registration.

The complete forum/PDF fix passed `swift build --disable-automatic-resolution`,
all 41 `RubienBrowserHostTests`, and all 16 extension Node tests. Swift tests
used an isolated temporary library. Live signed-in browser verification and
installation have not been performed.

Independent review found that queued PDF imports could lose the original
OpenReview URL. The correction preserves it in the metadata seed and missing
or local reference URLs, with durable confirmation assertions for both forum
and PDF inputs. The reviewer confirmed the correction with no further actionable
findings; the build and all 57 focused tests passed again. The optional
`/simplify` sweep was not requested.
