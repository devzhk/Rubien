#!/usr/bin/env node
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { parseArgs } from "node:util";
import { randomUUID } from "node:crypto";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { buildServer } from "./server.js";
import { requireBearer } from "./auth.js";
import { getCliVersion } from "./cli.js";
import { MIN_CLI_BUILD, evaluateCliVersion } from "./versionGuard.js";

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
  claude mcp add rubien node /path/to/mcp-server/dist/index.js

  # claude.ai (remote MCP)
  RUBIEN_MCP_BEARER=$(openssl rand -hex 32) \\
    node dist/index.js --http --port 4000 --bearer-token "$RUBIEN_MCP_BEARER"
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

  // Version guard: probe the resolved CLI once, before connecting any
  // transport. `--help` already exited inside parseCliArgs, so help works
  // even with no CLI installed.
  const guard = evaluateCliVersion(await getCliVersion(), MIN_CLI_BUILD);
  if (!guard.ok) {
    // Set exitCode + return rather than process.exit(1): the async stderr
    // write to a pipe can truncate if we exit immediately. No transport is
    // connected and the probe child has finished, so the event loop drains
    // and the process exits with code 1 after stderr flushes.
    process.stderr.write((guard.message ?? "rubien-cli version check failed") + "\n");
    process.exitCode = 1;
    return;
  }

  if (args.mode === "stdio") {
    await runStdio();
  } else {
    await runHttp(args.port, args.bearerToken!);
  }
}

main().catch((err: Error) => {
  process.stderr.write(`fatal: ${err.stack ?? err.message}\n`);
  process.exit(1);
});
