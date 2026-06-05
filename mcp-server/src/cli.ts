import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import { homedir } from "node:os";
import { join } from "node:path";
import type { CliVersion } from "./versionGuard.js";

const execFileAsync = promisify(execFile);

const DEFAULT_TIMEOUT_MS = 60_000;
const DEFAULT_MAX_BUFFER = 32 * 1024 * 1024;

export class CliError extends Error {
  constructor(
    message: string,
    public readonly exitCode: number | null,
    public readonly stderr: string,
  ) {
    super(message);
    this.name = "CliError";
  }
}

/**
 * Resolve the rubien-cli binary path, preferring the App-Group-entitled
 * embedded helper over any PATH-installed binary. A PATH CLI is usually an
 * unsigned SPM dev build that would hit a different library.sqlite than the
 * signed app.
 */
export function resolveCliPath(): string {
  const envOverride = process.env.RUBIEN_CLI;
  if (envOverride && envOverride.length > 0) {
    // Validate the env-pointed path so a stale value fails early with a
    // clear error rather than deep inside execFile.
    if (!existsSync(envOverride)) {
      throw new Error(
        `RUBIEN_CLI points at a path that does not exist: ${envOverride}`,
      );
    }
    return envOverride;
  }

  const candidates = [
    "/Applications/Rubien.app/Contents/Helpers/rubien-cli",
    join(homedir(), "Applications/Rubien.app/Contents/Helpers/rubien-cli"),
    // Dev path, matching scripts/build-app.sh output.
    join(process.cwd(), "build/Rubien.app/Contents/Helpers/rubien-cli"),
    join(process.cwd(), "../build/Rubien.app/Contents/Helpers/rubien-cli"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }

  // Fallback: `rubien-cli` on PATH. Last resort only — typically points at a
  // dev SPM build without the App Group entitlement, which would read a
  // different library.sqlite than the signed app.
  return "rubien-cli";
}

export interface CliOptions {
  /** Treat stdout as raw text (e.g. BibTeX, RIS) instead of JSON. */
  textMode?: boolean;
  /** Override the default 60s timeout for slow operations. */
  timeoutMs?: number;
  /** Write to stdin — used by `import -` with piped content. */
  stdin?: string;
}

/**
 * Invoke rubien-cli with the given argv and return the parsed result.
 *
 * Contract: on exit 0, stdout is JSON (default) or plain text (`textMode`).
 * On non-zero exit, stderr is `{"error": "..."}` per the contract pinned in
 * Tests/RubienCLITests/SwiftLibCLITests.swift:189; this function throws a
 * CliError with that message.
 */
export async function invokeCli(
  args: string[],
  options: CliOptions = {},
): Promise<unknown> {
  const cliPath = resolveCliPath();
  const timeout = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  try {
    const child = execFileAsync(cliPath, args, {
      timeout,
      maxBuffer: DEFAULT_MAX_BUFFER,
    });
    // Close stdin unconditionally. Even when we have nothing to pipe, leaving
    // it open causes subcommands that call `readDataToEndOfFile()` (like
    // `import -`) to block until the timeout fires.
    if (child.child.stdin) {
      if (options.stdin !== undefined) {
        child.child.stdin.write(options.stdin);
      }
      child.child.stdin.end();
    }
    const { stdout } = await child;

    if (options.textMode) {
      return { format: extractFormat(args), text: stdout };
    }

    const trimmed = stdout.trim();
    if (trimmed.length === 0) return null;
    return JSON.parse(trimmed);
  } catch (err: unknown) {
    // execFile error shape: { code, signal, stdout, stderr, message }
    const e = err as {
      code?: number;
      signal?: string;
      stdout?: string;
      stderr?: string;
      message?: string;
    };
    const stderr = (e.stderr ?? "").trim();
    let parsedError: string | undefined;
    if (stderr.length > 0) {
      try {
        const parsed = JSON.parse(stderr);
        if (parsed && typeof parsed === "object" && "error" in parsed) {
          parsedError = String(parsed.error);
        }
      } catch {
        // stderr wasn't JSON; fall through and use raw text.
      }
    }
    const message =
      parsedError ??
      (stderr.length > 0 ? stderr : (e.message ?? "rubien-cli invocation failed"));
    throw new CliError(
      message,
      typeof e.code === "number" ? e.code : null,
      stderr,
    );
  }
}

function extractFormat(args: string[]): string {
  const idx = args.indexOf("--format");
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  const idxShort = args.indexOf("-f");
  if (idxShort >= 0 && idxShort + 1 < args.length) return args[idxShort + 1];
  return "text";
}

/** Convenience: invoke and cast to a specific type. Caller is responsible
 *  for schema validation (use zod `.parse` at the call site). */
export async function invokeCliTyped<T>(args: string[], options: CliOptions = {}): Promise<T> {
  return (await invokeCli(args, options)) as T;
}

/**
 * Probe `rubien-cli version` with a short timeout. Returns the parsed
 * {version, build} or null on any failure (missing subcommand on an old CLI,
 * non-zero exit, malformed output, timeout). Never throws.
 */
export async function getCliVersion(): Promise<CliVersion | null> {
  try {
    const result = await invokeCli(["version"], { timeoutMs: 5_000 });
    if (
      result &&
      typeof result === "object" &&
      typeof (result as Record<string, unknown>).version === "string" &&
      typeof (result as Record<string, unknown>).build === "number"
    ) {
      return result as unknown as CliVersion;
    }
    return null;
  } catch {
    return null;
  }
}
