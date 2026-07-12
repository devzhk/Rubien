import { describe, it, expect } from "vitest";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const distIndex = join(process.cwd(), "dist", "index.js");
const fixtures = join(process.cwd(), "test", "fixtures");

/** Spawn the built server; resolve when it exits, or — after `graceMs` of
 *  staying alive — treat it as "started" (guard passed → it serves on stdin)
 *  and kill it. `graceMs` must exceed the 5s probe timeout for the hang test. */
function runServer(
  env: Record<string, string>,
  args: string[] = [],
  graceMs = 1_500,
): Promise<{ exitCode: number | null; stderr: string; started: boolean }> {
  return new Promise((resolve) => {
    const child = spawn("node", [distIndex, ...args], {
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (c) => (stderr += c.toString()));
    let settled = false;
    // Resolve on `close` (fires after stdio streams flush/EOF), NOT `exit` —
    // otherwise stderr can still be in-flight when we read it.
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      resolve({ exitCode: code, stderr, started: false });
    });
    setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill();
      resolve({ exitCode: null, stderr, started: true });
    }, graceMs);
  });
}

describe.skipIf(!existsSync(distIndex))("startup version guard", () => {
  it("refuses to start against a too-old CLI (stdio)", async () => {
    const r = await runServer({ RUBIEN_CLI: join(fixtures, "stub-cli-old.sh") });
    expect(r.started).toBe(false);
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("needs build >= 20");
  }, 10_000);

  it("refuses to start against a CLI with no version subcommand", async () => {
    const r = await runServer({ RUBIEN_CLI: join(fixtures, "stub-cli-noversion.sh") });
    expect(r.started).toBe(false);
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toMatch(/predates the 'version' command/i);
  }, 10_000);

  it("refuses to start in http mode too (valid port, so the GUARD — not arg validation — fires)", async () => {
    // index.ts rejects port <= 0 before the guard, so use a valid port to
    // prove the guard itself blocks startup.
    const r = await runServer(
      { RUBIEN_CLI: join(fixtures, "stub-cli-old.sh") },
      ["--http", "--port", "9999", "--bearer-token", "x"],
    );
    expect(r.started).toBe(false);
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("needs build >= 20");
  }, 10_000);

  it("aborts the probe against a hanging CLI within ~6s (5s timeout → null path)", async () => {
    const start = Date.now();
    const r = await runServer({ RUBIEN_CLI: join(fixtures, "stub-cli-hang.sh") }, [], 9_000);
    expect(r.started).toBe(false); // it exited, not still serving
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toMatch(/predates the 'version' command/i); // timeout → null → predates msg
    expect(Date.now() - start).toBeLessThan(8_000);
  }, 12_000);

  it("starts against an ok CLI", async () => {
    const r = await runServer({ RUBIEN_CLI: join(fixtures, "stub-cli-ok.sh") });
    expect(r.started).toBe(true);
  }, 10_000);

  it("--help exits 0 with NO cli present (guard must not run before --help)", async () => {
    const r = await runServer({ RUBIEN_CLI: "/nonexistent/rubien-cli" }, ["--help"]);
    expect(r.exitCode).toBe(0);
  }, 10_000);
});
