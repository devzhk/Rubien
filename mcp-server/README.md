# rubien-mcp-server

A Model Context Protocol server that wraps `rubien-cli`, making the Rubien reference library available to Claude Code, Claude Desktop, and claude.ai chat as a callable tool catalog.

The server is a thin Node/TypeScript process. It spawns `rubien-cli` under the hood and speaks MCP over one of two transports:

- **stdio** — used by **Claude Code** and **Claude Desktop**. The client launches the server as a child process and talks to it over the pipe. No network, no auth.
- **Streamable HTTP with bearer-token auth** — used by **claude.ai (web)** via a custom MCP connector. Requires a tunnel (e.g. Cloudflare Tunnel) because your library lives on your Mac.

Pick the section below that matches your client. Most users want one of the two stdio paths.

## Prerequisites

- Node.js ≥ 20
- `rubien-cli` reachable on the host. The server looks for it in this order:
  1. `$RUBIEN_CLI` env var (explicit path)
  2. `/Applications/Rubien.app/Contents/Helpers/rubien-cli` (installed app bundle)
  3. `~/Applications/Rubien.app/Contents/Helpers/rubien-cli`
  4. `./build/Rubien.app/Contents/Helpers/rubien-cli` (dev build output from `scripts/build-app.sh`)
  5. `rubien-cli` on `PATH` (last resort)

**Prefer the bundled helper**, because it's signed with the App Group entitlement and reads the same `library.sqlite` the Rubien app uses. A bare `rubien-cli` on PATH is typically an SPM dev build without the entitlement, which hits a *different* database — see the "Database location" note in `Docs/CLI-Reference.md`.

To pin the spawned CLI to a specific library directory regardless of which binary resolves, set `RUBIEN_LIBRARY_ROOT` in the MCP server's `env` block (Claude Code: `claude mcp add rubien --env RUBIEN_LIBRARY_ROOT=...`; Claude Desktop: under `mcpServers.rubien.env` in `claude_desktop_config.json`). The path is used verbatim — point it at the directory that contains `library.sqlite` (e.g. `~/Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien` for the sandboxed library, or `~/Library/Application Support/Rubien` for the unsandboxed one).

## Install & build

```bash
cd mcp-server
npm install
npm run build         # → dist/
npm test              # vitest unit tests
```

## Claude Code (stdio)

```bash
claude mcp add rubien node $(pwd)/dist/index.js
```

Try it:

> List my 5 most recently added references.
> Cite reference 42 in Nature style.

Claude Code's permission UI prompts for the destructive tools (`rubien_delete`, `rubien_update`, `rubien_import`, and the property/tag write tools) on first use.

## Claude Desktop (stdio)

Claude Desktop spawns MCP servers itself — no tunnel, no bearer token. Add Rubien to `claude_desktop_config.json` via either route:

- **Edit the file directly** at `~/Library/Application Support/Claude/claude_desktop_config.json`.
- **Settings → Developer → Edit Config** in Claude Desktop, which opens the same file in your editor.

Add Rubien under `mcpServers`:

```json
{
  "mcpServers": {
    "rubien": {
      "command": "node",
      "args": ["/absolute/path/to/Rubien/mcp-server/dist/index.js"]
    }
  }
}
```

Restart Claude Desktop and Rubien appears in the tool picker. To pin the spawned CLI to a specific library (see *Prerequisites* above for paths), add an `env` block:

```json
"rubien": {
  "command": "node",
  "args": ["/absolute/path/to/Rubien/mcp-server/dist/index.js"],
  "env": {
    "RUBIEN_LIBRARY_ROOT": "/Users/you/Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien"
  }
}
```

> **Future work — Desktop Extension (`.dxt`).** Claude Desktop also supports one-click MCP installs via `.dxt` packages (a zip containing a `manifest.json` + bundled server). Rubien doesn't ship one yet; packaging it would replace the config-file edit above with a double-click install from a GitHub Release asset.

## claude.ai web (Streamable HTTP + Cloudflare Tunnel)

claude.ai (the web app at https://claude.ai) can't spawn a local process, so it talks to the server over HTTPS via a custom MCP connector. Since your library lives on your Mac, you'll need a tunnel to expose the local server, and bearer-token auth to keep strangers out.

```bash
# 1. Start the server with a bearer token
RUBIEN_MCP_BEARER=$(openssl rand -hex 32) \
  node dist/index.js --http --port 4000 --bearer-token "$RUBIEN_MCP_BEARER"

# 2. Open a tunnel
cloudflared tunnel --url http://localhost:4000
# → copy the https://*.trycloudflare.com URL

# 3. In claude.ai: Settings → Connectors → Add custom MCP connector
#    URL:   https://<your-tunnel>.trycloudflare.com
#    Token: $RUBIEN_MCP_BEARER (from step 1)
```

Save the bearer token — you'll need it to reconnect after restarts.

## Security model

This server is designed for **single-user personal use** only.

- The bearer token is a long-lived static secret. There's no rotation, revocation, rate limiting, or replay protection.
- The server will happily accept any request with the correct token. Don't paste the token into anything you don't trust, and treat a leaked token like an SSH key — regenerate immediately.
- Cloudflare Tunnel provides TLS termination; the token travels over HTTPS. If you use a plaintext tunnel (e.g. raw ngrok HTTP) the token can be sniffed.
- A leaked URL without the token is safe — every request gets a 401 — but rotate both if in doubt.

If this setup ever becomes multi-user, the auth layer needs a real story: OAuth, short-lived tokens, and per-client revocation.

## Tool catalog

Roughly 36 tools covering every `rubien-cli` subcommand mode. Names are `rubien_<subject>_<action>` so Claude can pick the right tool from a single-word hint:

| Surface | Tools |
|---|---|
| References | `rubien_search`, `rubien_list`, `rubien_get`, `rubien_add`, `rubien_update`, `rubien_delete` |
| Citations | `rubien_cite`, `rubien_styles_list` |
| Import/Export | `rubien_import`, `rubien_export` |
| PDFs | `rubien_pdf_info`, `rubien_pdf_text`, `rubien_pdf_page_image`, `rubien_pdf_download` |
| Tags | `rubien_tags_list`, `rubien_tags_create`, `rubien_tags_delete`, `rubien_tags_rename`, `rubien_tags_assign`, `rubien_tags_remove` |
| Properties | `rubien_properties_list`, `rubien_properties_create`, `rubien_properties_delete`, `rubien_properties_rename`, `rubien_properties_show`, `rubien_properties_hide`, `rubien_properties_add_option`, `rubien_properties_set`, `rubien_properties_clear` |
| Saved views | `rubien_views_list`, `rubien_views_create`, `rubien_views_delete`, `rubien_views_rename`, `rubien_views_query` |
| Annotations | `rubien_annotations_list` |
| Sync | `rubien_sync_status` |

The PDF tools cover inspection and acquisition — `rubien_pdf_info` returns page count plus a flattened outline, `rubien_pdf_text` extracts text by page range or section title, `rubien_pdf_page_image` renders a page to PNG for figure inspection, and `rubien_pdf_download` fetches an open-access PDF for an existing reference and attaches it to the library.

Destructive tools are tagged with `destructiveHint: true` so Claude Code's permission UI flags them. `rubien_delete` always passes `--force` — the confirmation happens in the MCP client permission UI, not in the CLI's TTY prompt. See the comment in `src/tools/references.ts` for rationale.

## Contract pinning

Every tool's argument shape is defined in zod in the tool file; the expected *response* shape is in `src/schemas.ts`, mirroring the Swift DTOs in `Sources/RubienCLI/RubienCLI.swift` (search for `*DTO`). Crucial convention (see tests in `test/schemas.test.ts`):

- `.optional()` in zod for Swift `Optional` fields — Swift's `JSONEncoder` **omits** nil optionals from output.
- `.nullable()` only for `AlwaysEncodedOptional<T>` wrappers (currently just `DatabaseViewDTO.groupBy`).

If a Swift DTO changes, update both the Swift side and `src/schemas.ts` in the same commit, per the CLAUDE.md rule about keeping the CLI and data layer in lockstep.

## Development

```bash
npm run dev       # tsc --watch
npm run test:watch
```

MCP Inspector is the fastest way to poke at tool schemas by hand:

```bash
npx @modelcontextprotocol/inspector node dist/index.js
```
