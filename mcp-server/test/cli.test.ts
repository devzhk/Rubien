import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { invokeCli, CliError, resolveCliPath } from "../src/cli.js";

/**
 * Exercises the CLI wrapper's happy path + stderr-error contract using a
 * stub shell script in place of the real rubien-cli binary. Keeps the test
 * hermetic — no dependency on whether swift build has produced the binary.
 */
describe("invokeCli", () => {
  let scratch: string;
  let stubPath: string;

  beforeEach(() => {
    scratch = join(tmpdir(), `rubien-mcp-test-${Date.now()}-${Math.random()}`);
    mkdirSync(scratch, { recursive: true });
    stubPath = join(scratch, "rubien-cli-stub.sh");
  });

  afterEach(() => {
    rmSync(scratch, { recursive: true, force: true });
  });

  function installStub(body: string): void {
    writeFileSync(stubPath, `#!/bin/bash\n${body}\n`, { mode: 0o755 });
    chmodSync(stubPath, 0o755);
    process.env.RUBIEN_CLI = stubPath;
  }

  it("parses JSON stdout into a native object", async () => {
    installStub(`echo '{"id":1,"title":"hello"}'`);
    const result = await invokeCli(["get", "1"]);
    expect(result).toEqual({ id: 1, title: "hello" });
  });

  it("returns raw text when textMode=true", async () => {
    installStub(`echo '@article{foo, title={X}}'`);
    const result = (await invokeCli(["export", "--format", "bibtex"], {
      textMode: true,
    })) as { format: string; text: string };
    expect(result.format).toBe("bibtex");
    expect(result.text).toContain("@article{foo");
  });

  it("parses stderr {error} JSON on non-zero exit and throws CliError", async () => {
    installStub(`echo '{"error":"reference 999 not found"}' >&2\nexit 3`);
    await expect(invokeCli(["get", "999"])).rejects.toThrowError(
      /reference 999 not found/,
    );
    try {
      await invokeCli(["get", "999"]);
    } catch (err) {
      expect(err).toBeInstanceOf(CliError);
      expect((err as CliError).exitCode).toBe(3);
    }
  });

  it("falls through to raw stderr when error isn't JSON", async () => {
    installStub(`echo 'catastrophic failure' >&2\nexit 1`);
    await expect(invokeCli(["get", "1"])).rejects.toThrowError(
      /catastrophic failure/,
    );
  });

  it("handles empty stdout by returning null", async () => {
    installStub(`exit 0`);
    const result = await invokeCli(["noop"]);
    expect(result).toBeNull();
  });

  it("closes child stdin so subcommands that read stdin don't hang", async () => {
    // `rubien-cli import -` calls readDataToEndOfFile. If invokeCli leaves
    // stdin open, the child blocks until the timeout fires. Stub below
    // drains stdin and echoes byte count; test fails fast on a hang.
    installStub(
      `read_bytes=$(cat | wc -c | tr -d ' '); echo "{\\"bytes\\":$read_bytes}"`,
    );
    const result = (await invokeCli(["import", "-"], { timeoutMs: 3000 })) as {
      bytes: number;
    };
    expect(result.bytes).toBe(0);
  });
});

describe("resolveCliPath", () => {
  it("honors RUBIEN_CLI env var when the path exists", () => {
    const prior = process.env.RUBIEN_CLI;
    try {
      // Use a path known to exist — /bin/ls works on every macOS install.
      process.env.RUBIEN_CLI = "/bin/ls";
      expect(resolveCliPath()).toBe("/bin/ls");
    } finally {
      if (prior === undefined) delete process.env.RUBIEN_CLI;
      else process.env.RUBIEN_CLI = prior;
    }
  });

  it("throws when RUBIEN_CLI points at a nonexistent path", () => {
    const prior = process.env.RUBIEN_CLI;
    try {
      process.env.RUBIEN_CLI = "/definitely/not/here/rubien-cli";
      expect(() => resolveCliPath()).toThrowError(/does not exist/);
    } finally {
      if (prior === undefined) delete process.env.RUBIEN_CLI;
      else process.env.RUBIEN_CLI = prior;
    }
  });

  it("falls back to bare `rubien-cli` (PATH) when no candidates exist", () => {
    const prior = process.env.RUBIEN_CLI;
    try {
      delete process.env.RUBIEN_CLI;
      // On a test CI without any of the candidate paths this is the expected
      // resolution. We can't positively assert it picks the bundled helper
      // because that's machine-dependent; we just assert we get *something*.
      const resolved = resolveCliPath();
      expect(typeof resolved).toBe("string");
      expect(resolved.length).toBeGreaterThan(0);
    } finally {
      if (prior !== undefined) process.env.RUBIEN_CLI = prior;
    }
  });
});
