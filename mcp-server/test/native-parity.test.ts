import { existsSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { buildServer } from "../src/server.js";
import { AttachmentAddResult, ReferenceAttachmentStatus } from "../src/schemas.js";

const nativeCli = process.env.RUBIEN_CLI ?? resolve("../.build/debug/rubien-cli");

async function npmTools() {
  const server = buildServer();
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "native-parity-test", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return (await client.listTools()).tools;
}

async function nativeTools(): Promise<Array<Record<string, unknown>>> {
  const request = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} });
  const child = spawn(nativeCli, ["mcp"], { stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  child.stdin.end(request + "\n");
  const exitCode = await new Promise<number | null>((resolveExit, reject) => {
    child.on("error", reject);
    child.on("close", resolveExit);
  });
  expect(exitCode, stderr).toBe(0);
  const response = JSON.parse(stdout.trim()) as {
    result: { tools: Array<Record<string, unknown>> };
  };
  return response.result.tools;
}

async function nativeCall(
  name: string,
  args: Record<string, unknown>,
  libraryRoot: string,
): Promise<Record<string, unknown>> {
  const request = JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: { name, arguments: args },
  });
  const child = spawn(nativeCli, ["mcp"], {
    env: { ...process.env, RUBIEN_LIBRARY_ROOT: libraryRoot },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  child.stdin.end(request + "\n");
  const exitCode = await new Promise<number | null>((resolveExit, reject) => {
    child.on("error", reject);
    child.on("close", resolveExit);
  });
  expect(exitCode, stderr).toBe(0);
  return (JSON.parse(stdout.trim()) as { result: Record<string, unknown> }).result;
}

async function npmCall(
  name: string,
  args: Record<string, unknown>,
  libraryRoot: string,
): Promise<Record<string, unknown>> {
  const previousCli = process.env.RUBIEN_CLI;
  const previousRoot = process.env.RUBIEN_LIBRARY_ROOT;
  process.env.RUBIEN_CLI = nativeCli;
  process.env.RUBIEN_LIBRARY_ROOT = libraryRoot;
  const server = buildServer();
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "native-output-parity-test", version: "0.0.0" });
  try {
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    return await client.callTool({ name, arguments: args }) as Record<string, unknown>;
  } finally {
    await client.close();
    await server.close();
    if (previousCli === undefined) delete process.env.RUBIEN_CLI;
    else process.env.RUBIEN_CLI = previousCli;
    if (previousRoot === undefined) delete process.env.RUBIEN_LIBRARY_ROOT;
    else process.env.RUBIEN_LIBRARY_ROOT = previousRoot;
  }
}

function normalizedSchema(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalizedSchema);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([key]) => key !== "description" && key !== "$schema")
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, child]) => [key, normalizedSchema(child)]),
    );
  }
  return value;
}

function normalizedToolResult(result: Record<string, unknown>): unknown {
  const content = (result.content as Array<Record<string, unknown>>).map((block) => {
    if (block.type !== "text" || typeof block.text !== "string") return block;
    try {
      return { ...block, text: JSON.parse(block.text) as unknown };
    } catch {
      return block;
    }
  });
  return { content, isError: result.isError ?? false };
}

describe.skipIf(!existsSync(nativeCli))("native/npm MCP catalog parity", () => {
  it("adds, reads, exports, renames, and removes attachments through both servers", async () => {
    const root = mkdtempSync(resolve(tmpdir(), "rubien-attachment-parity-"));
    const body = (result: Record<string, unknown>) => {
      expect(result.isError).not.toBe(true);
      return JSON.parse((result.content as Array<{ text: string }>)[0].text);
    };
    try {
      const reference = body(await nativeCall("rubien_create_reference", { title: "Parent" }, root)).items[0].reference;
      const path = resolve(root, "notes with spaces.md");
      writeFileSync(path, "Supplement only 🐈\nSecond line");
      const added = body(await nativeCall("rubien_attachment_add", { referenceId: reference.id, files: [path] }, root));
      expect(added[0].outcome).toBe("added");
      expect(AttachmentAddResult.safeParse(added[0]).success).toBe(true);
      const id = added[0].status.attachment.syncId;
      expect(added[0].status.syncStatus).toBe("notEnabled");
      const duplicate = body(await npmCall("rubien_attachment_add", { referenceId: reference.id, files: [path] }, root));
      expect(duplicate[0].outcome).toBe("duplicate");
      expect(duplicate[0].status.attachment.syncId).toBe(id);
      for (const [name, args] of [
        ["rubien_attachment_list", { referenceId: reference.id }],
        ["rubien_attachment_status", { id }],
        ["rubien_attachment_retry", { id }],
        ["rubien_attachment_read", { id, start: 11, maxChars: 6 }],
        ["rubien_attachment_read", { id, pages: "1" }],
        ["rubien_attachment_status", { id: "not-a-uuid" }],
      ] as Array<[string, Record<string, unknown>]>) {
        expect(normalizedToolResult(await nativeCall(name, args, root)), name)
          .toEqual(normalizedToolResult(await npmCall(name, args, root)));
      }
      const renamed = body(await npmCall("rubien_attachment_rename", { id, name: "Supplement" }, root));
      expect(renamed.attachment.displayName).toBe("Supplement");
      expect(ReferenceAttachmentStatus.safeParse(renamed).success).toBe(true);
      const output = resolve(root, "copy.md");
      body(await npmCall("rubien_attachment_export", { id, output }, root));
      expect(readFileSync(output, "utf8")).toBe(readFileSync(path, "utf8"));
      expect((await nativeCall("rubien_attachment_export", { id, output }, root)).isError).toBe(true);
      const removed = body(await nativeCall("rubien_attachment_remove", { id }, root));
      expect(removed.localAvailability).toBe("removed");
      expect(ReferenceAttachmentStatus.safeParse(removed).success).toBe(true);
      expect(body(await npmCall("rubien_attachment_list", { referenceId: reference.id }, root))).toEqual([]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 30_000);

  it("matches all names, input schemas, and approval annotations", async () => {
    const [native, npm] = await Promise.all([nativeTools(), npmTools()]);
    const project = (tools: Array<Record<string, unknown>>) =>
      Object.fromEntries(
        tools.map((tool) => [tool.name as string, {
          inputSchema: normalizedSchema(tool.inputSchema),
          annotations: tool.annotations ?? {},
        }]),
      );

    expect(project(native)).toEqual(project(npm as Array<Record<string, unknown>>));
    expect(native).toHaveLength(36);
  });

  it("matches representative JSON and text-export output shaping", async () => {
    const libraryRoot = mkdtempSync(resolve(tmpdir(), "rubien-native-parity-"));
    try {
      for (const [name, args] of [
        ["rubien_list_references", {}],
        ["rubien_export", { format: "bibtex" }],
        ["rubien_export", { format: "ris" }],
      ] as Array<[string, Record<string, unknown>]>) {
        const native = await nativeCall(name, args, libraryRoot);
        const npm = await npmCall(name, args, libraryRoot);
        expect(normalizedToolResult(native), name).toEqual(normalizedToolResult(npm));
      }
    } finally {
      rmSync(libraryRoot, { recursive: true, force: true });
    }
  });
});
