# eLife Article Support Implementation Plan

**Goal:** Resolve `elifesciences.org/articles/<id>` URLs as scholarly references and fetch their open-access PDFs.

**Architecture:** Extend the existing paper-host allowlist with eLife article and PDF URL shapes. Resolve eLife metadata through its keyless official article API, then preserve the existing CrossRef merge and verification flow. Return the API's versioned PDF URL to Add-by-Identifier/CLI, and add an eLife direct-PDF fallback for downloads initiated later from a saved reference.

## Constraints

- Accept only numeric eLife article paths, not arbitrary pages on the domain.
- Keep the public `MetadataFetcher` and `PaperURLResolver` interfaces unchanged.
- Validate API status, content type, required metadata, authors, and PDF URL before returning.
- Retain the existing PDF content-type and magic-byte checks at download time.
- Cover landing URLs, `.pdf` URLs, API parsing, resolver wiring, and direct PDF URL construction without live-network-dependent tests.

## Tasks

- [x] Add failing host-classification, extraction, rewrite, resolver, and PDF URL tests.
- [x] Add eLife to `KnownPaperHost` and rewrite `.pdf` inputs to canonical landing pages.
- [x] Fetch and parse the official eLife article API response, returning its PDF URL through the existing override channel.
- [x] Add eLife direct PDF resolution for saved references.
- [x] Run focused tests, full build/test verification, independent review, and a simplification sweep.
