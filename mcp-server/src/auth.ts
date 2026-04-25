import type { IncomingMessage, ServerResponse } from "node:http";

/**
 * Constant-time string comparison. Avoids timing leaks on token verification.
 */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Validate Authorization header against the configured bearer token.
 * Writes a 401 to the response and returns false on mismatch.
 *
 * Single-user personal use model: the token is a long-lived static secret
 * provided via CLI flag / env var. No rotation or revocation. See
 * README.md → Security model for the full threat model.
 */
export function requireBearer(
  req: IncomingMessage,
  res: ServerResponse,
  expectedToken: string,
): boolean {
  const header = req.headers["authorization"];
  if (typeof header !== "string" || !header.startsWith("Bearer ")) {
    res.writeHead(401, { "WWW-Authenticate": "Bearer realm=\"rubien-mcp\"" });
    res.end('{"error":"missing or malformed Authorization header"}');
    return false;
  }
  const token = header.slice("Bearer ".length).trim();
  if (!safeEqual(token, expectedToken)) {
    res.writeHead(401, { "WWW-Authenticate": "Bearer realm=\"rubien-mcp\"" });
    res.end('{"error":"invalid bearer token"}');
    return false;
  }
  return true;
}
