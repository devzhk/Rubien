import { describe, it, expect } from "vitest";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * End-to-end test: boot the built server over stdio, drive a minimal
 * JSON-RPC handshake (initialize → tools/list → tools/call), and verify the
 * server returns sane responses — including a real WRITE (create_reference →
 * unified envelope → delete_reference) against the actual CLI, so the CI job
 * catches write-surface drift the mocked argv tests can't see.
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
      // Hermetic library so the real create/delete below never touches the
      // dev library — a fresh temp root the CLI migrates on first use.
      const libRoot = mkdtempSync(join(tmpdir(), "rubien-e2e-"));
      const child = spawn("node", [distIndex], {
        env: { ...process.env, RUBIEN_CLI: swiftCli, RUBIEN_LIBRARY_ROOT: libRoot },
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
        // The 0.3.0 {op}_{target} catalog is exactly 27 tools.
        expect(toolNames).toHaveLength(27);
        // Spot-check a few from each category.
        expect(toolNames).toContain("rubien_search_references");
        expect(toolNames).toContain("rubien_list_references");
        expect(toolNames).toContain("rubien_create_reference");
        expect(toolNames).toContain("rubien_update_reference");
        expect(toolNames).toContain("rubien_cite");
        expect(toolNames).toContain("rubien_list_styles");
        expect(toolNames).toContain("rubien_delete_reference");
        expect(toolNames).toContain("rubien_get_sync_status");
        expect(toolNames).toContain("rubien_read_text");
        expect(toolNames).toContain("rubien_read_annotations");
        expect(toolNames).toContain("rubien_grep_text");
        // Retired old-generation names must be gone.
        expect(toolNames).not.toContain("rubien_add");
        expect(toolNames).not.toContain("rubien_import");
        expect(toolNames).not.toContain("rubien_views_query");
        expect(toolNames).not.toContain("rubien_properties_set");
        // Sanity-check destructiveHint on delete.
        const deleteTool = (toolsResult.result.tools as Array<{
          name: string;
          annotations?: { destructiveHint?: boolean };
        }>).find((t) => t.name === "rubien_delete_reference");
        expect(deleteTool?.annotations?.destructiveHint).toBe(true);

        // 4. tools/call rubien_list_styles → should invoke real CLI and return
        //    something parseable. Exact content depends on local library
        //    state; we only assert structural success.
        const callResult = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: { name: "rubien_list_styles", arguments: {} },
        });
        expect(callResult.result).toBeDefined();
        expect(callResult.result.content).toBeDefined();
        expect(Array.isArray(callResult.result.content)).toBe(true);
        expect(callResult.result.isError).not.toBe(true);

        // 5. A real WRITE round-trip against the CLI: create_reference (title
        //    route) must return the unified {items,summary} envelope with a
        //    created item, then delete_reference cleans it up. This is the
        //    only place the advertised write surface is exercised end-to-end
        //    (the argv/envelope unit tests mock the CLI).
        const uniqueTitle = `e2e-write-${initResult.result.serverInfo?.name}-${child.pid}`;
        const createResult = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 4,
          method: "tools/call",
          params: {
            name: "rubien_create_reference",
            arguments: { title: uniqueTitle },
          },
        });
        expect(createResult.result.isError).not.toBe(true);
        const envText = (createResult.result.content as Array<{ text: string }>)[0].text;
        const envelope = JSON.parse(envText) as {
          items: Array<{ status: string; reference?: { id: number } }>;
          summary: { created: number };
        };
        expect(envelope.summary.created).toBe(1);
        expect(envelope.items[0].status).toBe("created");
        const newId = envelope.items[0].reference?.id;
        expect(typeof newId).toBe("number");

        const deleteResult = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 5,
          method: "tools/call",
          params: {
            name: "rubien_delete_reference",
            arguments: { ids: [newId] },
          },
        });
        expect(deleteResult.result.isError).not.toBe(true);
      } finally {
        child.kill();
        await new Promise<void>((resolve) => child.once("close", () => resolve()));
        rmSync(libRoot, { recursive: true, force: true });
      }
    },
    30_000,
  );
});

// Degraded mode needs only the built dist — the "CLI" is a stub script that
// flips from build 18 to build 99 when a marker file appears, standing in
// for the user updating Rubien.app mid-session.
describe.skipIf(!existsSync(distIndex))("e2e stdio degraded mode (version gate)", () => {
  it(
    "serves the catalog with a too-old CLI, errors per tool call, and recovers once the CLI updates",
    async () => {
      const dir = mkdtempSync(join(tmpdir(), "rubien-guard-e2e-"));
      const marker = join(dir, "cli-updated");
      const child = spawn("node", [distIndex], {
        env: {
          ...process.env,
          RUBIEN_CLI: join(process.cwd(), "test", "fixtures", "stub-cli-upgradeable.sh"),
          RUBIEN_STUB_MARKER: marker,
        },
        stdio: ["pipe", "pipe", "pipe"],
      });

      try {
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
        sendMessage(child, { jsonrpc: "2.0", method: "notifications/initialized" });

        // The catalog is fully advertised even while degraded — the client
        // must see a healthy server, not "Server disconnected".
        const toolsResult = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 2,
          method: "tools/list",
        });
        expect(
          (toolsResult.result.tools as Array<{ name: string }>).length,
        ).toBe(27);

        // Every call returns the update instruction as tool text.
        const degraded = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: { name: "rubien_list_views", arguments: {} },
        });
        expect(degraded.result.isError).toBe(true);
        const degradedText = (degraded.result.content as Array<{ text: string }>)[0].text;
        expect(degradedText).toContain("needs build >= 26");
        expect(degradedText).toMatch(/Update Rubien\.app/);

        // "Update Rubien.app" mid-session → the very next call recovers,
        // with no server or client restart.
        writeFileSync(marker, "");
        const recovered = await rpcRequest(child, {
          jsonrpc: "2.0",
          id: 4,
          method: "tools/call",
          params: { name: "rubien_list_views", arguments: {} },
        });
        expect(recovered.result.isError).not.toBe(true);
        const recoveredText = (recovered.result.content as Array<{ text: string }>)[0].text;
        expect(JSON.parse(recoveredText)).toEqual([]);
      } finally {
        child.kill();
        await new Promise<void>((resolve) => child.once("close", () => resolve()));
        rmSync(dir, { recursive: true, force: true });
      }
    },
    30_000,
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
