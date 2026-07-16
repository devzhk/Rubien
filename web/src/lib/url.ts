// Centralized URL-scheme validation. Reference URLs arrive from imported
// BibTeX/RIS/JSON files and remote metadata, so they are untrusted: an
// attacker-supplied `javascript:` (or `data:`) URL bound to an <a href> runs
// in the app origin on click. Every place that stores a URL for later linking
// or fetches a URL must pass it through here first.

const LINK_SCHEMES = new Set(["http:", "https:", "mailto:"]);
const FETCH_SCHEMES = new Set(["http:", "https:"]);

function tryParse(value: string): URL | undefined {
  try {
    return new URL(value);
  } catch {
    return undefined;
  }
}

/**
 * Returns a normalized URL safe to bind to an `href`, or `undefined` if the
 * value uses a disallowed scheme (e.g. `javascript:`, `data:`, `file:`).
 * A scheme-less value (e.g. `example.com/x`) is treated as `https://`.
 */
export function safeExternalURL(value: string | null | undefined): string | undefined {
  if (!value) return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  // A parseable value keeps its own scheme; only fall back to an https guess
  // when the value has no scheme at all (parse failure).
  const parsed = tryParse(trimmed) ?? tryParse(`https://${trimmed}`);
  if (!parsed) return undefined;
  return LINK_SCHEMES.has(parsed.protocol.toLowerCase()) ? parsed.href : undefined;
}

/**
 * Returns a URL safe to `fetch()` (http/https only, explicit scheme required),
 * or `undefined`. Stricter than {@link safeExternalURL}: no mailto, no scheme
 * guessing, so callers never issue a request to an unexpected scheme/target.
 */
export function safeFetchURL(value: string | null | undefined): string | undefined {
  if (!value) return undefined;
  const parsed = tryParse(value.trim());
  if (!parsed) return undefined;
  return FETCH_SCHEMES.has(parsed.protocol.toLowerCase()) ? parsed.href : undefined;
}
