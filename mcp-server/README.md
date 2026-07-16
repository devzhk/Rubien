# rubien-mcp-server

A Model Context Protocol server that wraps `rubien-cli`, exposing your Rubien library to Claude Code, Claude Desktop, and claude.ai (web) as a tool catalog. It spawns `rubien-cli` under the hood and speaks MCP over two transports:

- **stdio** — Claude Code and Claude Desktop. The client spawns the server locally. No network, no auth. What most people want; see [Install](#install).
- **Streamable HTTP + bearer token** — claude.ai (web) connects as a *remote MCP server* (it can't spawn a local process), so it needs a tunnel. See [claude.ai web](#claudeai-web-remote-mcp-server).

## Requirement: `rubien-cli` on the host

The server is only a wrapper. It needs **Node.js ≥ 20** and the `rubien-cli` binary:

- **Mac:** install **Rubien.app** (the DMG). The entitled `rubien-cli` ships inside it and is found automatically.
- **Linux:** install the runtime libs and extract the CLI tarball, keeping `rubien-cli` and its `*.resources` folders together (the CLI loads citation styles from beside the binary):
  ```bash
  sudo apt install libsqlite3-0 libcurl4 libxml2 libpoppler-glib8 libcairo2 libgdk-pixbuf-2.0-0 libglib2.0-0 ca-certificates
  # download rubien-cli-*-linux-x86_64.tar.gz, extract, then:
  export RUBIEN_CLI=/path/to/extracted/rubien-cli
  ```
  Tarball: <https://github.com/devzhk/Rubien-releases/releases>. Don't put the bare binary on `PATH` alone — it loses its resource bundles.

The server checks the CLI's build (`MIN_CLI_BUILD`). In stdio mode it starts either way: if the CLI is missing or too old, every tool call returns the update instruction as its result, re-checked per call — so updating Rubien mid-session recovers on the next call, with no client restart. (Versions ≤ 0.3.0 exited at startup instead, which Claude Desktop rendered as an opaque "Server disconnected" — see [Troubleshooting](#troubleshooting-server-disconnected-in-claude-desktop).) In `--http` mode the server still exits at startup, where stderr is visible in your terminal. Update via Rubien.app / Sparkle on Mac, or `rubien-cli self-update` on Linux.

## Install

Both stdio clients use the published npm package via `npx -y` — no global install.

### Claude Code

```bash
claude mcp add rubien -- npx -y rubien-mcp-server
```

### Claude Desktop

**Settings → Developer → Edit Config** (or edit `~/Library/Application Support/Claude/claude_desktop_config.json`), then restart Claude Desktop:

```json
{
  "mcpServers": {
    "rubien": {
      "command": "npx",
      "args": ["-y", "rubien-mcp-server"]
    }
  }
}
```

**macOS PATH gotcha:** Claude Desktop launches servers with launchd's minimal `PATH`, not your shell's. If `npx` isn't found, set `"command"` to its absolute path (`which npx` → e.g. `/opt/homebrew/bin/npx`). Affects every npx-based server; Claude Code is unaffected. No `.dxt` one-click package yet.

### Upgrading

The `npx -y rubien-mcp-server` install is **unpinned**, so there is nothing to reinstall — `npx` resolves the latest published version each time the client spawns the server. Upgrade in this order:

1. **Update Rubien first** — Sparkle on Mac (Rubien → Settings → Check Now), `rubien-cli self-update` on Linux. The server needs the new `rubien-cli`.
2. **Restart your MCP client** — quit/reopen Claude Desktop, or start a new Claude Code session. The respawned server is the latest release.

The pairing is guarded in one direction: a new server against a too-old Rubien **refuses every tool call with an update instruction** (`MIN_CLI_BUILD`), so a half-upgrade fails loudly instead of half-working. The other direction is why upgrading matters — an old server against a new Rubien breaks at tool-call time when it shells subcommands that no longer exist (server < 0.3.0 vs Rubien ≥ 0.4.0: the 0.4.0 CLI cutover removed `import`, `add --identifier`, `views --query`, and the legacy `properties` write flags that 0.1.x/0.2.x servers shell out to; those server versions are deprecated on npm for this reason).

If a stale `npx` cache ever keeps serving an old version after a restart, clear it (`rm -rf ~/.npm/_npx`) or pin `rubien-mcp-server@latest` in the config. HTTP mode (below) runs as a long-lived process you started yourself — it does not auto-upgrade; restart it after updating Rubien.

### Troubleshooting: "Server disconnected" in Claude Desktop

Claude Desktop never shows an MCP server's stderr — the actual error is in `~/Library/Logs/Claude/mcp-server-rubien.log`. Two known causes, both typically surfacing right after a reboot, because Claude Desktop only respawns MCP servers when the app itself relaunches:

- **Stale Rubien vs auto-upgraded server.** The unpinned `npx -y` install picks up new server releases at respawn; if Rubien.app hasn't been updated, the log shows `needs build >= N`. Fix: open Rubien.app and let Sparkle update it. Server ≥ 0.3.1 no longer disconnects for this — the instruction is returned to Claude on each tool call instead — but older servers exited at startup with only this log line as evidence.
- **No network at spawn.** `npx` resolves the package version against the npm registry on *every* spawn, even with a warm cache. If Claude Desktop launches at login before Wi-Fi/VPN is up, the spawn fails (`ENOTFOUND`/`ECONNREFUSED registry.npmjs.org` in the log) and Claude Desktop does not retry. Fix: quit and reopen Claude Desktop once online. To remove the network dependency entirely, install globally and point the config at the absolute path (`npm install -g rubien-mcp-server`, then `which rubien-mcp-server`) — at the cost of upgrading by hand with `npm update -g rubien-mcp-server`.

## claude.ai web (remote MCP server)

claude.ai connects to rubien as a **remote MCP server** over Streamable HTTP — it can't spawn a local process. It's the *same npm package* in HTTP mode: the server still runs on your Mac (where the library and `rubien-cli` live), and claude.ai reaches it through a Cloudflare Tunnel, with a bearer token to keep strangers out.

```bash
# 1. Start the server in HTTP mode with a bearer token
RUBIEN_MCP_BEARER=$(openssl rand -hex 32) \
  npx -y rubien-mcp-server --http --port 4000 --bearer-token "$RUBIEN_MCP_BEARER"

# 2. Open a tunnel
cloudflared tunnel --url http://localhost:4000
# → copy the https://*.trycloudflare.com URL

# 3. claude.ai → Settings → Connectors → Add custom MCP connector
#    URL: the tunnel URL;  Token: $RUBIEN_MCP_BEARER
```

Save the token — you need it to reconnect after restarts.

### Security model

The remote path is **single-user personal use only.**

- The bearer token is a long-lived static secret — no rotation, revocation, rate limiting, or replay protection. Treat it like an SSH key; regenerate if leaked.
- Cloudflare Tunnel terminates TLS, so the token travels over HTTPS. A plaintext tunnel (e.g. raw ngrok HTTP) exposes it to sniffing.
- A leaked URL without the token is safe (every request gets a 401) — but rotate both if in doubt.

Multi-user would need a real auth story: OAuth, short-lived tokens, per-client revocation.

## Optional configuration

### Pin the library directory

By default the CLI resolves its own library location. To force one, set `RUBIEN_LIBRARY_ROOT` to the directory containing `library.sqlite`:

- Claude Code: `claude mcp add rubien --env RUBIEN_LIBRARY_ROOT=<dir> -- npx -y rubien-mcp-server`
- Claude Desktop: add `"env": { "RUBIEN_LIBRARY_ROOT": "<dir>" }` beside `command`/`args`.

| Host | Directory |
|---|---|
| Mac (sandboxed app) | `~/Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien` |
| Mac (unsandboxed dev) | `~/Library/Application Support/Rubien` |
| Linux | `~/.local/share/rubien` (or `$XDG_DATA_HOME/rubien`) |

### How the server finds `rubien-cli`

First hit wins:

1. `$RUBIEN_CLI` (explicit path)
2. `/Applications/Rubien.app/Contents/Helpers/rubien-cli` (Mac)
3. `~/Applications/Rubien.app/Contents/Helpers/rubien-cli` (Mac)
4. `./build/Rubien.app/Contents/Helpers/rubien-cli` (dev build, Mac)
5. `rubien-cli` on `PATH` (Linux installs land here)

**On Mac, prefer the bundled helper** (2–4): it's signed with the App Group entitlement and reads the same `library.sqlite` as the app. A bare `rubien-cli` on PATH is usually an unentitled dev build hitting a *different* database (see "Database location" in `Docs/CLI-Reference.md`).

**On Linux**, everything works except `rubien_get_sync_status` (no CloudKit — the `sync` subcommand isn't built).

### Run a local checkout

For development, point the client at a built `dist/` (see [Development](#development)):

```bash
claude mcp add rubien -- node $(pwd)/dist/index.js        # Claude Code
```
```json
{ "mcpServers": { "rubien": { "command": "node", "args": ["/abs/path/to/mcp-server/dist/index.js"] } } }
```

## Tool catalog

28 tools — CRUD operations always carry the target suffix (`create_reference`, `update_property`); a bare verb appears only when the operation is unique and unambiguous (`cite`, `export`):

| Surface | Tools |
|---|---|
| References | `rubien_search_references`, `rubien_list_references`, `rubien_get_reference`, `rubien_create_reference`, `rubien_update_reference`, `rubien_delete_reference` |
| Citations | `rubien_cite`, `rubien_list_styles` |
| Export | `rubien_export` |
| Reading | `rubien_read_text`, `rubien_read_annotations`, `rubien_grep_text` |
| Activity | `rubien_reading_activity` |
| PDFs | `rubien_get_pdf_info`, `rubien_render_pdf_page`, `rubien_download_pdf` |
| Properties (columns + options, incl. Tags) | `rubien_list_properties`, `rubien_create_property`, `rubien_update_property`, `rubien_delete_property`, `rubien_create_option`, `rubien_update_option`, `rubien_delete_option` |
| Saved views | `rubien_list_views`, `rubien_create_view`, `rubien_update_view`, `rubien_delete_view` |
| Sync | `rubien_get_sync_status` (Mac-only — errors on Linux) |

`rubien_create_reference` is the **one door in**: pass exactly one of `source` (any locator — DOI / arXiv / PMID / PMCID / ISBN, paper URL, PDF/Markdown file URL, absolute file path, or folder path; the CLI routes it), `bibtex`, or `title`. It may return multiple items (multi-entry BibTeX, folders) and `status: "existing"` when dedup matched, in the unified `{items, summary, diagnostics}` envelope. Stdin (`"-"`) is intentionally unavailable through MCP.

Per-reference property values (cells) are edited through `rubien_update_reference`'s `properties` payload — `{"Status": "Reading", "Tags": {"add": ["12"]}, "7": ["ml", "nlp"], "Themes": null}` — atomically alongside metadata fields. The option tools (`create_option` / `update_option` / `delete_option`) manage the *choices themselves* (including Tag rows for the built-in Tags property).

Reading tools operate on any reference without your knowing whether it holds a PDF or a clipped web page. `rubien_read_text` returns the readable body text — the attached PDF or the clipped web page — routed automatically: omit `source` and `pages`/`sections` imply the PDF, `start` implies the web body, else PDF wins when both exist. Every response reports `source` (what was read) and `available` (which sources are readable now). PDF results are page-keyed (`pages[]` items with `text` + `sectionPath`, selected by a `pages` range or `sections` title-substrings); web results are one paginated body window (`content` + `contentLength`, `start`/`maxChars`; `contentFormat` markdown or HTML). `rubien_read_annotations` merges the user's highlights/underlines/anchored notes across both kinds into one array, each item tagged `source`; web items carry a W3C TextQuoteSelector triple (`prefixText`/`anchorText`/`suffixText`) that locates them inside the `rubien_read_text` body. `rubien_grep_text` is the lookup half of the same workflow: it finds *where* a reference's body mentions a phrase or regex — PDF hits grouped by page (`sectionPath` breadcrumbs), web hits as exact character offsets — so you can then pull just those spots with `rubien_read_text` (`pages` for PDF, `start` for web). All three are library-only — none hit the network.

PDF tools: `rubien_get_pdf_info` (page count, `hasTextLayer`, outline sections — call it before selecting `rubien_read_text` by `sections`), `rubien_render_pdf_page` (render a page to an image, for tables/figures/equations), `rubien_download_pdf` (fetch an open-access PDF and attach it to an existing reference).

Destructive tools carry `destructiveHint: true` so Claude Code's permission UI flags them. `rubien_delete_reference` passes `--force`; confirmation happens in the client UI, not a CLI prompt (see `src/tools/references.ts`).

## Contract pinning

Argument shapes are zod schemas in each tool file; response shapes are in `src/schemas.ts`, mirroring the Swift `*DTO` types in `Sources/RubienCLI/RubienCLI.swift`. Convention (tested in `test/schemas.test.ts`):

- `.optional()` for Swift `Optional` fields — `JSONEncoder` omits nil optionals.
- `.nullable()` only for `AlwaysEncodedOptional<T>` (currently just `DatabaseViewDTO.groupBy`).

Change a Swift DTO → update `src/schemas.ts` in the same commit (CLAUDE.md CLI/data-layer lockstep rule).

## Development

```bash
cd mcp-server
npm install
npm run build         # → dist/
npm test              # vitest
npm run dev           # tsc --watch
```

Poke at tool schemas by hand with MCP Inspector:

```bash
npx @modelcontextprotocol/inspector node dist/index.js
```
