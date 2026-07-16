#!/usr/bin/env node
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { parseArgs } from "node:util";
import { randomUUID } from "node:crypto";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { buildServer } from "./server.js";
import { requireBearer } from "./auth.js";
import { MIN_CLI_BUILD, ensureCliCompatible } from "./versionGuard.js";

const USAGE = `Usage:
  rubien-mcp-server [--stdio]
  rubien-mcp-server --http --port <port> --bearer-token <token>

Options:
  --stdio              Start in stdio mode (default; use from Claude Code via \`claude mcp add\`).
  --http               Start an HTTP server (use with Cloudflare Tunnel for claude.ai).
  --port <n>           Port for HTTP mode (default 4000). Env: RUBIEN_MCP_PORT.
  --bearer-token <t>   Required bearer token for HTTP mode. Env: RUBIEN_MCP_BEARER.
  --help               Show this message.

Examples:
  # Claude Code
  claude mcp add rubien -- npx -y rubien-mcp-server

  # claude.ai (remote MCP) — same package, HTTP mode
  RUBIEN_MCP_BEARER=$(openssl rand -hex 32) \\
    npx -y rubien-mcp-server --http --port 4000 --bearer-token "$RUBIEN_MCP_BEARER"
  # then: cloudflared tunnel --url http://localhost:4000
`;

interface ParsedArgs {
  mode: "stdio" | "http";
  port: number;
  bearerToken?: string;
}

function parseCliArgs(argv: string[]): ParsedArgs {
  const { values } = parseArgs({
    args: argv,
    options: {
      stdio: { type: "boolean" },
      http: { type: "boolean" },
      port: { type: "string" },
      "bearer-token": { type: "string" },
      help: { type: "boolean" },
    },
    allowPositionals: false,
  });

  if (values.help) {
    process.stdout.write(USAGE);
    process.exit(0);
  }

  const mode: "stdio" | "http" = values.http ? "http" : "stdio";
  const port = Number(
    values.port ?? process.env.RUBIEN_MCP_PORT ?? "4000",
  );
  const bearerToken =
    (values["bearer-token"] as string | undefined) ??
    process.env.RUBIEN_MCP_BEARER;

  if (mode === "http") {
    if (!bearerToken) {
      process.stderr.write(
        "--bearer-token (or RUBIEN_MCP_BEARER env) is required in --http mode\n",
      );
      process.exit(2);
    }
    if (!Number.isFinite(port) || port <= 0 || port > 65535) {
      process.stderr.write(`invalid --port: ${port}\n`);
      process.exit(2);
    }
  }
  return { mode, port, bearerToken };
}

async function runStdio(): Promise<void> {
  const server = buildServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // MCP stdio transport keeps the process alive via stdin.
  //
  // CLI compatibility is deliberately NOT checked before connecting —
  // buildServer gates every tool call instead (see cliGateError in
  // toolHelpers.ts for why). The startup probe below only logs the verdict
  // to stderr (e.g. ~/Library/Logs/Claude/mcp-server-rubien.log).
  void ensureCliCompatible().then(
    (guard) => {
      process.stderr.write(
        guard.ok
          ? `rubien-mcp-server: rubien-cli build ${guard.info?.build ?? "?"} >= ${MIN_CLI_BUILD} — compatible\n`
          : `${guard.message}\n`,
      );
    },
    () => {
      // ensureCliCompatible never rejects by contract; guard anyway so a
      // bug there can't become an unhandled rejection that kills the server.
    },
  );
}

async function runHttp(port: number, bearerToken: string): Promise<void> {
  const server = buildServer();
  // Stateful single-session transport. We generate a new session ID per
  // connection — single-user personal use doesn't need stateless.
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
  });
  await server.connect(transport);

  const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    // Public unauthenticated paths: nothing.
    if (!requireBearer(req, res, bearerToken)) return;
    try {
      await transport.handleRequest(req, res);
    } catch (err) {
      process.stderr.write(
        `handleRequest failed: ${(err as Error).message}\n`,
      );
      if (!res.writableEnded) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end('{"error":"internal transport error"}');
      }
    }
  });

  await new Promise<void>((resolve) => httpServer.listen(port, resolve));
  process.stderr.write(
    `rubien-mcp-server listening on http://127.0.0.1:${port}\n`,
  );
}

async function main(): Promise<void> {
  const args = parseCliArgs(process.argv.slice(2));

  if (args.mode === "stdio") {
    await runStdio();
    return;
  }

  // HTTP mode keeps the fail-fast startup guard: the process is started by
  // hand in a terminal where stderr is actually visible, and a long-lived
  // degraded server behind a tunnel would be easier to miss than an
  // immediate exit. `--help` already exited inside parseCliArgs, so help
  // works even with no CLI installed.
  const guard = await ensureCliCompatible();
  if (!guard.ok) {
    // Set exitCode + return rather than process.exit(1): the async stderr
    // write to a pipe can truncate if we exit immediately. No transport is
    // connected and the probe child has finished, so the event loop drains
    // and the process exits with code 1 after stderr flushes.
    process.stderr.write(guard.message + "\n");
    process.exitCode = 1;
    return;
  }
  await runHttp(args.port, args.bearerToken!);
}

main().catch((err: Error) => {
  process.stderr.write(`fatal: ${err.stack ?? err.message}\n`);
  process.exit(1);
});
