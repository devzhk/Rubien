import { describe, it, expect, vi } from "vitest";

// Mock ONLY the probe — the gate, the registration wrapper, and every tool
// handler stay real. This proves the buildServer registration seam gates the
// ENTIRE catalog, so a future bespoke handler that bypasses runCliAsTool
// (like rubien_render_pdf_page's typed-image path) cannot ship ungated.
vi.mock("../src/cli.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli.js")>();
  return {
    ...actual,
    probeCliVersion: vi.fn(async () => ({
      kind: "ok",
      info: { version: "0.2.3", build: 18 },
      envOverride: false,
    })),
  };
});

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { buildServer } from "../src/server.js";

/** Minimal argument object satisfying a tool's required input fields —
 *  enough to clear the SDK's schema validation so the call reaches the
 *  (gated) handler. */
function minimalArgs(inputSchema: unknown): Record<string, unknown> {
  const schema = inputSchema as {
    required?: string[];
    properties?: Record<string, unknown>;
  };
  const required = schema?.required ?? [];
  const properties = schema?.properties ?? {};
  return Object.fromEntries(
    required.map((key) => [key, sampleValue(properties[key])]),
  );
}

function sampleValue(propSchema: unknown): unknown {
  const s = propSchema as
    | {
        type?: string | string[];
        enum?: unknown[];
        items?: unknown;
        anyOf?: unknown[];
        required?: string[];
        properties?: Record<string, unknown>;
      }
    | undefined;
  if (!s) return "x";
  if (s.enum?.length) return s.enum[0];
  if (s.anyOf?.length) return sampleValue(s.anyOf[0]);
  const type = Array.isArray(s.type) ? s.type[0] : s.type;
  switch (type) {
    case "number":
    case "integer":
      return 1;
    case "boolean":
      return true;
    case "array":
      return [sampleValue(s.items)];
    case "object":
      return minimalArgs(s);
    default:
      return "x";
  }
}

describe("version-gate invariant", () => {
  it("EVERY registered tool returns the update instruction against a too-old CLI", async () => {
    const server = buildServer();
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test", version: "0.0.0" });
    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport),
    ]);

    const { tools } = await client.listTools();
    expect(tools.length).toBeGreaterThan(0);

    for (const tool of tools) {
      const result = await client.callTool({
        name: tool.name,
        arguments: minimalArgs(tool.inputSchema),
      });
      expect(result.isError, `${tool.name} must be gated`).toBe(true);
      const text =
        (result.content as Array<{ text?: string }>)[0]?.text ?? "";
      expect(
        text,
        `${tool.name} must carry the update instruction, got: ${text}`,
      ).toContain("needs build >= 28");
    }
  });
});
