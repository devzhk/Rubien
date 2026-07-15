# Unified Add Reference — Implementation Plan

**Date:** 2026-07-14

## Goal

Replace the toolbar's separate paper, website, and PDF/Markdown choices with one **Add Reference** button and one intake field. Classify the submitted source automatically, then hand it to the existing specialized review flow.

## Routing contract

1. Existing PDF/Markdown paths, direct PDF/Markdown URLs, and files chosen from the open panel use the existing materialization and file-review pipeline.
2. Recognized identifiers and paper-host URLs use metadata resolution. All remaining non-URL text is treated as a paper title search.
3. Other HTTP(S) URLs use the existing web clipper.
4. Unsupported URL schemes and existing directories are rejected in the intake sheet with a clear error.

## Implementation

1. Add a pure, testable app-intake router in `RubienCore`, reusing `ImportRouter` for path, paper-host, identifier, and direct-file classification.
2. Evolve the PDF/Markdown source sheet into the unified intake sheet while preserving its picker, security-scoped file handling, and duplicate-submission latch.
3. Prefill and automatically start metadata resolution for paper inputs; prefill the web clipper for website inputs.
4. Replace the toolbar menu with one Add Reference button and hand off to the appropriate existing sheet only after the intake sheet dismisses.
5. Add router/state tests, build, run focused tests, review the diff, and relaunch the worktree app.

## Non-goals

- No changes to metadata confidence, pending-review, web extraction, or PDF/Markdown persistence behavior.
- Advanced manual, batch, BibTeX, RIS, and Zotero imports remain in **More import options**.
