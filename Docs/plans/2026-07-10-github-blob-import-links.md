# GitHub Blob Import Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let copied GitHub `/blob/` links for supported PDF and Markdown files import through the existing direct-file pipeline.

**Architecture:** Recognize only `github.com/<owner>/<repo>/blob/...` URLs and add/replace GitHub's `raw=1` query flag before source classification and download. GitHub performs the redirect to its raw file endpoint; existing extension, HTTP response, media type, UTF-8/PDF magic, size, and temporary-file checks remain authoritative.

**Tech Stack:** Swift 6, Foundation `URLComponents`, XCTest URLProtocol stubs, existing RubienCore source materializer.

## Global Constraints

- Support only the exact `github.com` file-page shape; do not scrape arbitrary HTML pages or add private-repository authentication.
- Preserve original user input in `MaterializedImportSource.input` and preserve non-`raw` query parameters.
- Replace any existing `raw` query item with `raw=1` so a copied URL cannot opt out of the raw download.
- Keep all existing supported-extension and response-content validation unchanged after normalization.
- Keep `Docs/CLI-Reference.md` accurate for the CLI/MCP shared import contract.

---

### Task 1: Normalize supported GitHub blob links before acquisition

**Files:**
- Modify: `Sources/RubienCore/Services/ImportSourceMaterializer.swift`
- Modify: `Tests/RubienCoreTests/ImportSourceMaterializerTests.swift`
- Modify: `Docs/CLI-Reference.md`

**Interfaces:**
- `ImportSourceMaterializer.materialize(_:localPathPolicy:session:)` continues to accept the original string and returns it unchanged in `MaterializedImportSource.input`.
- New private helper: `normalizeGitHubBlobURL(_ url: URL) -> URL` returns either the original URL or an equivalent `github.com` blob URL whose query contains exactly one `raw=1` item.

- [ ] **Step 1: Write failing PDF and Markdown URLProtocol tests**

Add tests that pass a copied GitHub blob URL to `ImportSourceMaterializer.materialize`, but register the URLProtocol response only for its expected `?raw=1` request URL. The PDF test uses `application/octet-stream` plus `%PDF`; the Markdown test uses `text/plain`. Include an existing `raw=0` item and another query item in the PDF test so the expected request is `?download=1&raw=1`.

```swift
let input = "https://github.com/acme/research/blob/main/paper.pdf?raw=0&download=1"
let requestedRawURL = "https://github.com/acme/research/blob/main/paper.pdf?download=1&raw=1"
ImportSourceURLProtocol.stub(
    requestedRawURL,
    contentType: "application/octet-stream",
    data: Data("%PDF-1.7\\nGitHub raw".utf8)
)
let materialized = try await ImportSourceMaterializer.materialize(
    input,
    localPathPolicy: .requireAbsolute,
    session: ImportSourceURLProtocol.makeSession()
)
XCTAssertEqual(materialized.input, input)
XCTAssertEqual(materialized.kind, .pdf)
```

- [ ] **Step 2: Verify the tests fail before normalization exists**

Run: `swift test --filter ImportSourceMaterializerTests/testGitHubBlob`

Expected: both tests fail because the URLProtocol has a raw-query stub but the materializer requests the original blob URL.

- [ ] **Step 3: Add the narrow URL normalizer**

In `ImportSourceMaterializer.materialize`, call the helper after confirming HTTP(S) and a non-nil host, then pass the normalized URL to `materializeRemote` while retaining `trimmedInput` as the source input. The helper must require host `github.com`, at least owner/repository/blob/ref/file path components, and the literal `blob` component. It must remove all case-insensitive `raw` query items, append `raw=1`, preserve all other query items, and fall back to the original URL if `URLComponents` cannot rebuild it.

```swift
let normalizedURL = normalizeGitHubBlobURL(candidateURL)
return try await materializeRemote(
    input: trimmedInput,
    url: normalizedURL,
    session: session
)
```

- [ ] **Step 4: Verify focused tests and contract documentation**

Run: `swift test --filter ImportSourceMaterializerTests`

Expected: the existing materializer suite plus the new GitHub PDF/Markdown cases pass. Update `Docs/CLI-Reference.md` to state that GitHub `/blob/` file links are converted to GitHub's raw download before normal validation, while private/authenticated links may still fail.

- [ ] **Step 5: Commit the focused change**

```bash
git add Sources/RubienCore/Services/ImportSourceMaterializer.swift \
  Tests/RubienCoreTests/ImportSourceMaterializerTests.swift \
  Docs/CLI-Reference.md \
  Docs/plans/2026-07-10-github-blob-import-links.md
git commit -m "feat(import): support GitHub blob file links"
```

## Self-Review

- Scope coverage: Task 1 normalizes only approved GitHub file links, keeps all existing validation, covers both supported source kinds, and updates the shared CLI/MCP documentation.
- Placeholder scan: no unresolved steps or unspecified error behavior remain; unsupported and private links continue through the existing clear validation failures.
- Type consistency: the helper consumes and returns `URL`; the public materializer signature and materialized-source contract are unchanged.

## Execution Choice

This is one testable task with no independent subsystem. Per the approved narrow design, execute it inline in this isolated worktree with the existing test-first workflow.
