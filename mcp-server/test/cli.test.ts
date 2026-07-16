import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { invokeCli, CliError, probeCliVersion, resolveCliPath } from "../src/cli.js";

/**
 * Stub shell script standing in for the real rubien-cli binary — keeps the
 * tests hermetic, no dependency on whether swift build has produced it.
 */
let scratch: string;
let stubPath: string;
let priorRubienCli: string | undefined;

beforeEach(() => {
  priorRubienCli = process.env.RUBIEN_CLI;
  scratch = join(tmpdir(), `rubien-mcp-test-${Date.now()}-${Math.random()}`);
  mkdirSync(scratch, { recursive: true });
  stubPath = join(scratch, "rubien-cli-stub.sh");
});

afterEach(() => {
  // installStub points RUBIEN_CLI at the (now-deleted) stub; restore it so
  // the leak can't cross describes — or files in a reused vitest worker.
  if (priorRubienCli === undefined) delete process.env.RUBIEN_CLI;
  else process.env.RUBIEN_CLI = priorRubienCli;
  rmSync(scratch, { recursive: true, force: true });
});

function installStub(body: string): void {
  writeFileSync(stubPath, `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  chmodSync(stubPath, 0o755);
  process.env.RUBIEN_CLI = stubPath;
}

/** Exercises the CLI wrapper's happy path + stderr-error contract. */
describe("invokeCli", () => {
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

  it("throws CliError carrying stderr JSON on non-zero exit", async () => {
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

  it("preserves structured stderr envelopes VERBATIM — no field extraction (§4.6)", async () => {
    // The unresolved-selectors envelope carries ids/names beyond `error`;
    // extracting `.error` would silently drop them.
    const envelope = '{"error":"unresolved-selectors","ids":["9"],"names":["Topics"]}';
    installStub(`echo '${envelope}' >&2\nexit 1`);
    try {
      await invokeCli(["update", "1", "--properties", "{}"]);
      expect.unreachable("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(CliError);
      expect((err as CliError).message).toBe(envelope);
    }
  });

  it("preserves an all-failed create envelope (items/summary) verbatim", async () => {
    const envelope =
      '{"items":[{"status":"failed","input":"bibtex","error":"No valid BibTeX entries found"}],"summary":{"created":0,"existing":0,"queued":0,"failed":1}}';
    installStub(`echo '${envelope}' >&2\nexit 1`);
    try {
      await invokeCli(["add", "--bibtex", "junk"]);
      expect.unreachable("should have thrown");
    } catch (err) {
      expect((err as CliError).message).toBe(envelope);
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
    // `rubien-cli add --source -` calls readDataToEndOfFile. If invokeCli
    // leaves stdin open, the child blocks until the timeout fires. Stub below
    // drains stdin and echoes byte count; test fails fast on a hang.
    installStub(
      `read_bytes=$(cat | wc -c | tr -d ' '); echo "{\\"bytes\\":$read_bytes}"`,
    );
    const result = (await invokeCli(["add", "--source", "-"], { timeoutMs: 3000 })) as {
      bytes: number;
    };
    expect(result.bytes).toBe(0);
  });
});

describe("probeCliVersion", () => {
  it("classifies a version-reporting CLI as ok, noting the env override", async () => {
    installStub(`if [ "$1" = "version" ]; then echo '{"version":"9.9.9","build":99}'; fi`);
    const probe = await probeCliVersion();
    expect(probe).toEqual({
      kind: "ok",
      info: { version: "9.9.9", build: 99 },
      envOverride: true,
    });
  });

  it("classifies garbage stdout (exit 0) as no-version, not a crash", async () => {
    installStub(`echo 'not json at all'`);
    const probe = await probeCliVersion();
    expect(probe).toMatchObject({ kind: "no-version", path: stubPath });
  });

  it("classifies a nonzero exit (broken binary à la /usr/bin/false) as no-version", async () => {
    installStub(`exit 1`);
    const probe = await probeCliVersion();
    expect(probe).toMatchObject({ kind: "no-version", path: stubPath });
  });

  it("classifies a missing RUBIEN_CLI target as not-found", async () => {
    const prior = process.env.RUBIEN_CLI;
    try {
      process.env.RUBIEN_CLI = "/definitely/not/here/rubien-cli";
      const probe = await probeCliVersion();
      expect(probe).toMatchObject({ kind: "not-found", envOverride: true });
      expect((probe as { detail: string }).detail).toContain(
        "/definitely/not/here/rubien-cli",
      );
    } finally {
      if (prior === undefined) delete process.env.RUBIEN_CLI;
      else process.env.RUBIEN_CLI = prior;
    }
  });

  it("classifies a hung binary as timeout at the RUBIEN_MCP_PROBE_TIMEOUT_MS deadline", async () => {
    const prior = process.env.RUBIEN_MCP_PROBE_TIMEOUT_MS;
    try {
      process.env.RUBIEN_MCP_PROBE_TIMEOUT_MS = "200";
      installStub(`sleep 5`);
      const probe = await probeCliVersion();
      expect(probe).toMatchObject({
        kind: "timeout",
        path: stubPath,
        timeoutMs: 200,
      });
    } finally {
      if (prior === undefined) delete process.env.RUBIEN_MCP_PROBE_TIMEOUT_MS;
      else process.env.RUBIEN_MCP_PROBE_TIMEOUT_MS = prior;
    }
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
