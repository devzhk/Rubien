import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { cliGateError } from "./toolHelpers.js";
import { registerReferenceTools } from "./tools/references.js";
import { registerCitationTools } from "./tools/citations.js";
import { registerIOTools } from "./tools/io.js";
import { registerPropertyTools } from "./tools/properties.js";
import { registerViewTools } from "./tools/views.js";
import { registerSyncTools } from "./tools/sync.js";
import { registerPdfTools } from "./tools/pdf.js";
import { registerReadTools } from "./tools/read.js";

export const SERVER_INFO = {
  name: "rubien-mcp-server",
  version: "0.3.1",
} as const;

export function buildServer(): McpServer {
  const server = new McpServer(SERVER_INFO, {
    capabilities: { tools: {} },
  });

  gateAllTools(server);
  registerReferenceTools(server);
  registerCitationTools(server);
  registerIOTools(server);
  // Tags are exposed through the `properties` family against the built-in
  // Tags PropertyDefinition (defaultFieldKey == "tags"). The standalone
  // rubien_tags_* tool family was retired — see properties.ts.
  registerPropertyTools(server);
  registerViewTools(server);
  registerPdfTools(server);
  registerReadTools(server);
  registerSyncTools(server);

  return server;
}

/**
 * Prefix every tool registered after this call with the rubien-cli
 * compatibility gate (cliGateError). Applied at the registration seam so the
 * invariant is structural: every tool shells out to rubien-cli, so none can
 * do anything useful with an incompatible one, and a future bespoke handler
 * that skips runCliAsTool (like rubien_render_pdf_page's typed-image path)
 * cannot silently ship ungated. test/gate-invariant.test.ts enforces this
 * across the whole catalog.
 */
function gateAllTools(server: McpServer): void {
  const original = server.registerTool.bind(server);
  // registerTool's generic signature doesn't survive a wrapping assignment;
  // the cast is contained here.
  server.registerTool = ((name, config, handler) =>
    original(name, config, (async (...handlerArgs: unknown[]) => {
      const gateError = await cliGateError();
      if (gateError) return gateError;
      return (handler as (...a: unknown[]) => unknown)(...handlerArgs);
    }) as typeof handler)) as typeof server.registerTool;
}
