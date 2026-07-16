import { describe, it, expect } from "vitest";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const distIndex = join(process.cwd(), "dist", "index.js");
const fixtures = join(process.cwd(), "test", "fixtures");

/**
 * Spawn the built server and watch its lifecycle:
 * - resolves with `started: false` when it exits on its own;
 * - with `waitStderr` set, resolves with `started: true` as soon as the
 *   accumulated stderr matches (then kills the child) — startup timing under
 *   parallel vitest workers is too variable for a fixed sleep;
 * - otherwise (and as a fallback) resolves with `started: true` after
 *   `deadlineMs` of the child staying alive.
 */
function runServer(
  env: Record<string, string>,
  args: string[] = [],
  opts: { waitStderr?: RegExp; deadlineMs?: number } = {},
): Promise<{ exitCode: number | null; stderr: string; started: boolean }> {
  const deadlineMs = opts.deadlineMs ?? (opts.waitStderr ? 10_000 : 1_500);
  return new Promise((resolve) => {
    const child = spawn("node", [distIndex, ...args], {
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stderr = "";
    let settled = false;
    const settle = (result: { exitCode: number | null; started: boolean }) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ ...result, stderr });
    };
    child.stderr.on("data", (c) => {
      stderr += c.toString();
      if (opts.waitStderr?.test(stderr)) {
        child.kill();
        settle({ exitCode: null, started: true });
      }
    });
    // Resolve on `close` (fires after stdio streams flush/EOF), NOT `exit` —
    // otherwise stderr can still be in-flight when we read it.
    child.on("close", (code) => settle({ exitCode: code, started: false }));
    const timer = setTimeout(() => {
      child.kill();
      settle({ exitCode: null, started: true });
    }, deadlineMs);
  });
}

describe.skipIf(!existsSync(distIndex))("startup version guard", () => {
  // Stdio mode must START despite a bad CLI — exiting turns into an opaque
  // "Server disconnected" in Claude Desktop (the update instruction lands
  // invisibly in a log file). The verdict is still logged to stderr, and
  // tool calls carry the instruction (covered in e2e-stdio.test.ts).
  it("stdio: starts DEGRADED against a too-old CLI and logs the update instruction", async () => {
    const r = await runServer(
      { RUBIEN_CLI: join(fixtures, "stub-cli-old.sh") },
      [],
      { waitStderr: /needs build >= 26/ },
    );
    expect(r.started).toBe(true);
    expect(r.stderr).toContain("needs build >= 26");
  }, 15_000);

  it("stdio: starts against a CLI with no version subcommand, logging the predates message", async () => {
    const r = await runServer(
      { RUBIEN_CLI: join(fixtures, "stub-cli-noversion.sh") },
      [],
      { waitStderr: /predates the 'version' command/i },
    );
    expect(r.started).toBe(true);
    expect(r.stderr).toMatch(/predates the 'version' command/i);
  }, 15_000);

  it("stdio: starts with NO CLI present, logging the install instruction", async () => {
    const r = await runServer(
      { RUBIEN_CLI: "/nonexistent/rubien-cli" },
      [],
      { waitStderr: /Install Rubien\.app/ },
    );
    expect(r.started).toBe(true);
    expect(r.stderr).toContain("/nonexistent/rubien-cli");
    expect(r.stderr).toMatch(/Install Rubien\.app/);
  }, 15_000);

  it("stdio: starts against a hanging CLI, logging a timeout (not the predates message)", async () => {
    const r = await runServer(
      {
        RUBIEN_CLI: join(fixtures, "stub-cli-hang.sh"),
        RUBIEN_MCP_PROBE_TIMEOUT_MS: "1000",
      },
      [],
      { waitStderr: /within 1s/ },
    );
    expect(r.started).toBe(true);
    expect(r.stderr).toMatch(/did not answer 'version' within 1s/);
    expect(r.stderr).not.toMatch(/predates/i);
  }, 15_000);

  it("stdio: starts against an ok CLI and logs compatibility", async () => {
    const r = await runServer(
      { RUBIEN_CLI: join(fixtures, "stub-cli-ok.sh") },
      [],
      { waitStderr: /compatible/ },
    );
    expect(r.started).toBe(true);
    expect(r.stderr).toContain("compatible");
  }, 15_000);

  // HTTP mode keeps fail-fast: it's started by hand in a terminal where
  // stderr is visible, and a degraded server behind a tunnel is easy to miss.
  it("http: refuses to start against a too-old CLI (valid port, so the GUARD — not arg validation — fires)", async () => {
    const r = await runServer(
      { RUBIEN_CLI: join(fixtures, "stub-cli-old.sh") },
      ["--http", "--port", "9999", "--bearer-token", "x"],
      { deadlineMs: 10_000 },
    );
    expect(r.started).toBe(false);
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("needs build >= 26");
  }, 15_000);

  it("--help exits 0 with NO cli present (guard must not run before --help)", async () => {
    const r = await runServer({ RUBIEN_CLI: "/nonexistent/rubien-cli" }, ["--help"], {
      deadlineMs: 10_000,
    });
    expect(r.exitCode).toBe(0);
  }, 15_000);
});
