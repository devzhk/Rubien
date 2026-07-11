import { describe, it, expect, vi } from "vitest";

// Mock the CLI runner BEFORE importing the server so registerIOTools
// captures the mock. Match ../src/toolHelpers.js's actual export names.
vi.mock("../src/toolHelpers.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/toolHelpers.js")>();
  return {
    ...actual,
    runCliAsTool: vi.fn(async (args: string[]) => ({
      content: [{ type: "text", text: JSON.stringify({ echoedArgs: args }) }],
    })),
  };
});

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { buildServer } from "../src/server.js";
import { runCliAsTool } from "../src/toolHelpers.js";

async function connectedClient() {
  const server = buildServer();
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return client;
}

describe("rubien_import", () => {
  it("advertises md format and folder-neutral stamping descriptions", async () => {
    const client = await connectedClient();
    const tools = await client.listTools();
    const importTool = tools.tools.find((t) => t.name === "rubien_import");
    expect(importTool).toBeDefined();
    const schema = JSON.stringify(importTool!.inputSchema);
    expect(schema).toContain('"md"');
    expect(schema).not.toContain("Zotero folder only");
  });

  it("advertises absolute paths or direct HTTP(S) URLs for PDF and Markdown imports", async () => {
    const client = await connectedClient();
    const tools = await client.listTools();
    const importTool = tools.tools.find((t) => t.name === "rubien_import");
    expect(importTool).toBeDefined();
    const schema = JSON.stringify(importTool!.inputSchema);
    expect(schema).toContain("HTTP(S) URL");
    expect(schema).toContain(".pdf");
  });

  it("forwards format/property/value to the CLI", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_import",
      arguments: {
        file: "/tmp/Clippings",
        format: "md",
        property: "Tags",
        value: "Clippings",
      },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenCalledWith(
      ["import", "/tmp/Clippings", "--format", "md", "--property", "Tags", "--value", "Clippings"],
      expect.anything(),
    );
  });

  it("forwards a direct HTTPS PDF URL verbatim to the CLI", async () => {
    const client = await connectedClient();
    const source = "https://example.com/papers/direct-source.pdf";

    await client.callTool({
      name: "rubien_import",
      arguments: { file: source },
    });

    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith(
      ["import", source],
      expect.anything(),
    );
  });
});
