import { CliError, invokeCli, type CliOptions } from "./cli.js";

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
      return {
        content: [{ type: "text" as const, text: err.message }],
        isError: true,
      };
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
