import { describe, it, expect, vi } from "vitest";

// Mock the CLI runner BEFORE importing the server so the register* functions
// capture the mock. Match ../src/toolHelpers.js's actual export names.
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

/** The full 0.3.0 catalog — the {op}_{target} grid (spec §3). */
const EXPECTED_CATALOG = [
  // references
  "rubien_search_references",
  "rubien_list_references",
  "rubien_get_reference",
  "rubien_create_reference",
  "rubien_update_reference",
  "rubien_delete_reference",
  // properties (columns) + options
  "rubien_list_properties",
  "rubien_create_property",
  "rubien_update_property",
  "rubien_delete_property",
  "rubien_create_option",
  "rubien_update_option",
  "rubien_delete_option",
  // views
  "rubien_list_views",
  "rubien_create_view",
  "rubien_update_view",
  "rubien_delete_view",
  // citations
  "rubien_cite",
  "rubien_list_styles",
  // io
  "rubien_export",
  // pdf
  "rubien_get_pdf_info",
  "rubien_render_pdf_page",
  "rubien_download_pdf",
  // read
  "rubien_read_text",
  "rubien_read_annotations",
  "rubien_grep_text",
  // sync
  "rubien_get_sync_status",
].sort();

describe("0.3.0 catalog", () => {
  it("registers exactly the 27 {op}_{target} tools — no old names", async () => {
    const client = await connectedClient();
    const tools = await client.listTools();
    const names = tools.tools.map((t) => t.name).sort();
    expect(names).toEqual(EXPECTED_CATALOG);
    expect(names).toHaveLength(27);
  });

  it("create_reference is non-destructive; delete tools are destructive", async () => {
    const client = await connectedClient();
    const tools = await client.listTools();
    const byName = new Map(tools.tools.map((t) => [t.name, t]));
    expect(byName.get("rubien_create_reference")?.annotations?.destructiveHint).toBe(false);
    expect(byName.get("rubien_delete_reference")?.annotations?.destructiveHint).toBe(true);
    expect(byName.get("rubien_delete_property")?.annotations?.destructiveHint).toBe(true);
    expect(byName.get("rubien_delete_option")?.annotations?.destructiveHint).toBe(true);
    expect(byName.get("rubien_delete_view")?.annotations?.destructiveHint).toBe(true);
  });
});

describe("rubien_create_reference argv routing", () => {
  it("forwards a source locator with the route-independent 300s timeout", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_create_reference",
      arguments: { source: "10.1038/s41586-021-03819-2" },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith(
      ["add", "--source", "10.1038/s41586-021-03819-2"],
      { timeoutMs: 300_000 },
    );
  });

  it("emits --download-pdf for downloadPdf: true", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_create_reference",
      arguments: { source: "2106.04561", downloadPdf: true },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith(
      ["add", "--source", "2106.04561", "--download-pdf"],
      { timeoutMs: 300_000 },
    );
  });

  it("emits --no-download-pdf for downloadPdf: false (tri-state)", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_create_reference",
      arguments: {
        source: "https://aclanthology.org/2025.acl-long.1141.pdf",
        downloadPdf: false,
      },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith(
      [
        "add",
        "--source",
        "https://aclanthology.org/2025.acl-long.1141.pdf",
        "--no-download-pdf",
      ],
      { timeoutMs: 300_000 },
    );
  });

  it("omits both flags when downloadPdf is absent (router decides)", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_create_reference",
      arguments: { source: "PMC4587766" },
    });
    const args = vi.mocked(runCliAsTool).mock.lastCall?.[0] as string[];
    expect(args).not.toContain("--download-pdf");
    expect(args).not.toContain("--no-download-pdf");
  });

  it("forwards folder-route options (format/property/value)", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_create_reference",
      arguments: {
        source: "/tmp/Clippings",
        format: "md",
        property: "Tags",
        value: "Clippings",
      },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith(
      [
        "add",
        "--source",
        "/tmp/Clippings",
        "--format",
        "md",
        "--property",
        "Tags",
        "--value",
        "Clippings",
      ],
      { timeoutMs: 300_000 },
    );
  });

  it("routes inline bibtex and title through the same door", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_create_reference",
      arguments: { bibtex: "@article{x, title={T}}" },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith(
      ["add", "--bibtex", "@article{x, title={T}}"],
      { timeoutMs: 300_000 },
    );
    await client.callTool({
      name: "rubien_create_reference",
      arguments: { title: "My Paper" },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith(
      ["add", "--title", "My Paper"],
      { timeoutMs: 300_000 },
    );
  });

  it("rejects stdin ('-') without invoking the CLI", async () => {
    const client = await connectedClient();
    const before = vi.mocked(runCliAsTool).mock.calls.length;
    const result = await client.callTool({
      name: "rubien_create_reference",
      arguments: { source: "-" },
    });
    expect(result.isError).toBe(true);
    expect(JSON.stringify(result.content)).toContain("stdin");
    expect(vi.mocked(runCliAsTool).mock.calls.length).toBe(before);
  });

  it("rejects zero and multiple inputs without invoking the CLI", async () => {
    const client = await connectedClient();
    const before = vi.mocked(runCliAsTool).mock.calls.length;
    const none = await client.callTool({
      name: "rubien_create_reference",
      arguments: {},
    });
    expect(none.isError).toBe(true);
    const both = await client.callTool({
      name: "rubien_create_reference",
      arguments: { source: "10.1/x", title: "T" },
    });
    expect(both.isError).toBe(true);
    expect(JSON.stringify(both.content)).toContain("exactly one");
    expect(vi.mocked(runCliAsTool).mock.calls.length).toBe(before);
  });
});

describe("rubien_update_reference argv", () => {
  it("passes the properties payload as one JSON --properties flag", async () => {
    const client = await connectedClient();
    const payload = {
      Status: "Reading",
      Tags: { add: ["12"], remove: ["3"] },
      "7": ["ml", "nlp"],
      Themes: null,
    };
    await client.callTool({
      name: "rubien_update_reference",
      arguments: { id: 42, year: 2024, properties: payload },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "update",
      "42",
      "--year",
      "2024",
      "--properties",
      JSON.stringify(payload),
    ]);
  });

  it("maps clearFields to repeated --clear-field flags", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_update_reference",
      arguments: { id: 7, clearFields: ["abstract", "doi"] },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "update",
      "7",
      "--clear-field",
      "abstract",
      "--clear-field",
      "doi",
    ]);
  });

  it("accepts a free-string readingStatus (no frozen enum)", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_update_reference",
      arguments: { id: 7, readingStatus: "Skimming Again" },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "update",
      "7",
      "--reading-status",
      "Skimming Again",
    ]);
  });
});

describe("property/option/view tool argv", () => {
  it("update_property maps name/visible to --update --name/--set-visible", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_update_property",
      arguments: { id: "9", name: "Topics", visible: false },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "properties",
      "--update",
      "--id",
      "9",
      "--name",
      "Topics",
      "--set-visible",
      "false",
    ]);
  });

  it("update_option maps option/name/color to --update-option --option/--to/--color", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_update_option",
      arguments: { propertyId: "3", option: "low", name: "lowest", color: "#00FF00" },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "properties",
      "--update-option",
      "--id",
      "3",
      "--option",
      "low",
      "--to",
      "lowest",
      "--color",
      "#00FF00",
    ]);
  });

  it("create_option maps propertyId to --add-option --id", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_create_option",
      arguments: { propertyId: "5", value: "ml", color: "#123456" },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "properties",
      "--add-option",
      "--id",
      "5",
      "--value",
      "ml",
      "--color",
      "#123456",
    ]);
  });

  it("update_view / delete_view use the id-as-option-value CLI forms", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_update_view",
      arguments: { id: 4, name: "Recent" },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "views",
      "--rename",
      "4",
      "--name",
      "Recent",
    ]);
    await client.callTool({ name: "rubien_delete_view", arguments: { id: 4 } });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "views",
      "--delete",
      "4",
    ]);
  });
});

describe("rubien_list_references view param", () => {
  it("forwards view as --view (saved-view route)", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_list_references",
      arguments: { view: 12, limit: 5, offset: 5 },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenLastCalledWith([
      "list",
      "--limit",
      "5",
      "--offset",
      "5",
      "--view",
      "12",
    ]);
  });
});
