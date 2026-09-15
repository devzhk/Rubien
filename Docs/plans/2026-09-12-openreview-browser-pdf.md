# OpenReview browser PDF import

The signed-in browser can display OpenReview `/pdf?id=…` URLs while native
metadata requests receive a verification challenge. Import the browser download
through the existing PDF pipeline without depending on a forum-page fetch.

1. Recognize OpenReview PDF and forum tabs in Chrome download staging. Forum
   URLs map to the PDF endpoint using the same paper ID. Capture the forum's
   rendered `citation_*` metadata before staging the PDF, because an
   authenticated browser can read it even when Rubien's direct request is
   challenged.
2. Accept their token-bound PDF downloads in the native host and route them to
   PDF preparation. Retain file validation, preview/confirmation, and cleanup.
3. Cover authenticated staging, routing without publisher resolution, invalid
   downloads, and preservation of a PDF when metadata needs review.
4. Update browser import documentation; build and run focused tests.

Scope: browser imports only. No changes to CLI contracts, shared URL routing,
schema, dependencies, releases, or installed host registration.

The initial forum/PDF fix passed `swift build --disable-automatic-resolution`,
all 41 `RubienBrowserHostTests`, and all 16 extension Node tests. Its candidate
smoke test exposed that the forum capture was skipped, leaving a downloaded PDF
with malformed embedded author metadata. Capture and merge the authenticated
forum metadata into unresolved PDF review records, then repeat validation and
the candidate smoke test.

Independent review found that queued PDF imports could lose the original
OpenReview URL. The correction preserves it in the metadata seed and missing
or local reference URLs, with durable confirmation assertions for both forum
and PDF inputs. The reviewer confirmed the correction with no further actionable
findings; the build and all 57 focused tests passed again. The optional
`/simplify` sweep was not requested.
