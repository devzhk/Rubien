# Agent-facing web Markdown

## Outcome

Keep extracted HTML as the canonical web-reader body while giving the CLI and
in-app agents a compact Markdown representation by default. Explicit
`--format html` requests continue to expose the extracted HTML fragment.

## Storage

- Add a v12 local-only `webContentMarkdownCache` table keyed by `referenceId`.
- Cache rows carry the source-HTML SHA-256 and converter version, so content or
  converter changes invalidate them without mutating the synced reference.
- Imported Markdown remains canonical and needs no derived cache row.
- Existing HTML clips are converted and cached lazily on first Markdown read.

## Conversion

- Add a deterministic, Foundation-only HTML-to-Markdown projector in
  `RubienCore` so macOS and Linux CLI behavior stays aligned.
- Preserve headings, lists, links, code, tables, images, and block quotes.
- Collapse MathML to its `data-latex`/`alttext` representation to avoid sending
  the verbose MathML subtree to agents.
- Remove scripts, styles, comments, and presentational wrappers/attributes.

## CLI and MCP contract

- `read text` and `grep` accept `--format markdown|html` for web content.
- Markdown is the default. `--format` implies the web source and conflicts with
  an explicit PDF source.
- Web responses report both `contentFormat` (returned representation) and
  `sourceFormat` (canonical stored representation).
- `grep` and `read text --start` operate on the same chosen representation so
  offsets remain round-trippable.
- Both the native Swift MCP catalog and the Node MCP server forward the format.

## Verification

- Core tests cover projection fidelity, MathML compaction, cache reuse, source
  invalidation, and migration shape.
- CLI tests cover Markdown-by-default, explicit HTML, format validation, output
  metadata, and grep/read offset parity.
- MCP tests cover schema advertisement and forwarding.
- Run focused Core, CLI, and MCP tests, then build and review the full diff.
