import { describe, it, expect } from "vitest";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

/**
 * End-to-end test: boot the built server over stdio, drive a minimal
 * JSON-RPC handshake (initialize → tools/list → tools/call rubien_styles_list),
 * and verify the server returns sane responses.
 *
 * Gated on:
 *   - dist/index.js built (npm run build)
 *   - .build/debug/rubien-cli built (swift build)
 * If either is missing the test is skipped rather than failing, since we
 * don't want CI noise from unrelated build issues.
 */
const distIndex = join(process.cwd(), "dist", "index.js");
const swiftCli = join(process.cwd(), "..", ".build", "debug", "rubien-cli");

const skipReason = !existsSync(distIndex)
  ? "dist/index.js not built — run `npm run build` first"
  : !existsSync(swiftCli)
    ? "rubien-cli not built — run `swift build` at repo root first"
    : null;

describe.skipIf(skipReason !== null)("e2e stdio JSON-RPC", () => {
  it(
    "initialize → tools/list returns the full Rubien tool catalog",
    async () => {
      const child = spawn("node", [distIndex], {
        env: { ...process.env, RUBIEN_CLI: swiftCli },
        stdio: ["pipe", "pipe", "pipe"],
      });

      try {
        // 1. initialize
        const initResult = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2024-11-05",
            capabilities: {},
            clientInfo: { name: "vitest", version: "0.0.0" },
          },
        });
        expect(initResult.result).toBeDefined();
        expect(initResult.result.serverInfo?.name).toBe("rubien-mcp-server");

        // 2. notifications/initialized (required by spec, no response)
        sendMessage(child, {
          jsonrpc: "2.0",
          method: "notifications/initialized",
        });

        // 3. tools/list
        const toolsResult = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 2,
          method: "tools/list",
        });
        expect(toolsResult.result).toBeDefined();
        const toolNames = (toolsResult.result.tools as Array<{ name: string }>)
          .map((t) => t.name);
        // Spot-check a few from each category.
        expect(toolNames).toContain("rubien_search");
        expect(toolNames).toContain("rubien_list");
        expect(toolNames).toContain("rubien_cite");
        expect(toolNames).toContain("rubien_styles_list");
        expect(toolNames).toContain("rubien_delete");
        expect(toolNames).toContain("rubien_sync_status");
        // Sanity-check destructiveHint on delete.
        const deleteTool = (toolsResult.result.tools as Array<{
          name: string;
          annotations?: { destructiveHint?: boolean };
        }>).find((t) => t.name === "rubien_delete");
        expect(deleteTool?.annotations?.destructiveHint).toBe(true);

        // 4. tools/call rubien_styles_list → should invoke real CLI and return
        //    something parseable. Exact content depends on local library
        //    state; we only assert structural success.
        const callResult = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: { name: "rubien_styles_list", arguments: {} },
        });
        expect(callResult.result).toBeDefined();
        expect(callResult.result.content).toBeDefined();
        expect(Array.isArray(callResult.result.content)).toBe(true);
        expect(callResult.result.isError).not.toBe(true);
      } finally {
        child.kill();
        await new Promise<void>((resolve) => child.once("close", () => resolve()));
      }
    },
    15_000,
  );
});

// ----- JSON-RPC over stdio helpers -----

function sendMessage(
  child: ChildProcessWithoutNullStreams,
  msg: Record<string, unknown>,
): void {
  child.stdin.write(JSON.stringify(msg) + "\n");
}

async function rpcRequest(
  child: ChildProcessWithoutNullStreams,
  request: { id: number; jsonrpc: string; method: string; params?: unknown },
): Promise<{ result: Record<string, unknown>; [k: string]: unknown }> {
  return new Promise((resolve, reject) => {
    let buffer = "";
    const onData = (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      while (true) {
        const nl = buffer.indexOf("\n");
        if (nl < 0) break;
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        try {
          const msg = JSON.parse(line);
          if (msg.id === request.id) {
            child.stdout.off("data", onData);
            child.stderr.off("data", onErr);
            if (msg.error) reject(new Error(JSON.stringify(msg.error)));
            else resolve(msg);
            return;
          }
        } catch (e) {
          // Not every stdout line is JSON (e.g. debug logs). Ignore.
        }
      }
    };
    const onErr = (chunk: Buffer) => {
      // Server may write informational logs to stderr; don't fail the test on them.
      // Surface them only on timeout.
      void chunk;
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onErr);
    sendMessage(child, request);

    setTimeout(() => {
      child.stdout.off("data", onData);
      child.stderr.off("data", onErr);
      reject(new Error(`timeout waiting for response to id=${request.id}`));
    }, 10_000);
  });
}
