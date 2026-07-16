import { CliError, invokeCli, type CliOptions } from "./cli.js";
import { ensureCliCompatible } from "./versionGuard.js";

/** An `isError` CallToolResult carrying plain text. */
export function errorResult(text: string) {
  return {
    content: [{ type: "text" as const, text }],
    isError: true,
  };
}

/**
 * Version gate applied to every registered tool by buildServer (server.ts):
 * when rubien-cli is missing or too old, return the update instruction as an
 * `isError` tool result instead of failing some other way. Stdio clients
 * (Claude Desktop) hide server stderr behind a generic "Server disconnected",
 * so tool-call text is the only surface the user actually sees; the gate
 * re-probes on every failing call, so updating Rubien mid-session recovers
 * without a client restart. Returns null when the CLI is compatible.
 */
export async function cliGateError() {
  const guard = await ensureCliCompatible();
  if (guard.ok) return null;
  return errorResult(guard.message);
}

/**
 * Invoke rubien-cli and wrap the result as a CallToolResult. Errors from the
 * CLI are mapped to `isError: true` with the stderr message. Any other error
 * (missing binary, timeout) propagates as an exception which the MCP SDK
 * converts into a protocol-level error.
 *
 * We only return text content (pretty-printed JSON). MCP's `structuredContent`
 * expects an object-shape, but many CLI responses are arrays — returning them
 * as plain text keeps the Claude-facing contract simple and lossless.
 */
export async function runCliAsTool(args: string[], options: CliOptions = {}) {
  try {
    const result = await invokeCli(args, options);
    const asText =
      typeof result === "string" ? result : JSON.stringify(result, null, 2);
    return {
      content: [{ type: "text" as const, text: asText }],
    };
  } catch (err: unknown) {
    if (err instanceof CliError) {
      return errorResult(err.message);
    }
    throw err;
  }
}

/**
 * Filter undefined values out of an optional-argument map and render them as
 * `--flag value` / `--flag` pairs. Undefined/null skip the flag entirely.
 */
export function flagsFromOptions(
  opts: Record<string, string | number | boolean | undefined | null>,
): string[] {
  const out: string[] = [];
  for (const [key, value] of Object.entries(opts)) {
    if (value === undefined || value === null) continue;
    if (typeof value === "boolean") {
      if (value) out.push(key);
      continue;
    }
    out.push(key, String(value));
  }
  return out;
}
