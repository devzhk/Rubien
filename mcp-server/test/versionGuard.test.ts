import { describe, it, expect, vi, beforeEach } from "vitest";
import { MIN_CLI_BUILD, evaluateCliProbe } from "../src/versionGuard.js";

function expectFailure(
  r: ReturnType<typeof evaluateCliProbe>,
): asserts r is { ok: false; message: string } {
  expect(r.ok).toBe(false);
}

describe("evaluateCliProbe", () => {
  it("accepts a build >= MIN_CLI_BUILD and carries the version info", () => {
    const info = { version: "0.3.5", build: MIN_CLI_BUILD };
    const r = evaluateCliProbe(
      { kind: "ok", info, envOverride: false },
      MIN_CLI_BUILD,
    );
    expect(r).toEqual({ ok: true, info });
  });

  it("rejects build 18 because it predates the unified write surface (build 26 floor)", () => {
    const r = evaluateCliProbe(
      { kind: "ok", info: { version: "0.2.3", build: 18 }, envOverride: false },
      MIN_CLI_BUILD,
    );
    expectFailure(r);
    expect(r.message).toContain("build 18");
    expect(r.message).toContain(">= 26");
    expect(r.message).toMatch(/Update Rubien\.app|download a newer rubien-cli/i);
    expect(r.message).not.toContain("RUBIEN_CLI override");
  });

  it("points at the RUBIEN_CLI override when the too-old CLI came from it", () => {
    const r = evaluateCliProbe(
      { kind: "ok", info: { version: "0.2.3", build: 18 }, envOverride: true },
      MIN_CLI_BUILD,
    );
    expectFailure(r);
    expect(r.message).toContain("RUBIEN_CLI override");
  });

  it("rejects no-version naming the binary, without claiming to know it's old (could be broken)", () => {
    const r = evaluateCliProbe(
      { kind: "no-version", path: "/x/rubien-cli", envOverride: false },
      MIN_CLI_BUILD,
    );
    expectFailure(r);
    expect(r.message).toContain("/x/rubien-cli");
    expect(r.message).toMatch(/predates the 'version' command/i);
    expect(r.message).toMatch(/broken/i);
  });

  it("rejects not-found with an install instruction naming the probed location", () => {
    const r = evaluateCliProbe(
      {
        kind: "not-found",
        detail: "no rubien-cli at /x/rubien-cli",
        envOverride: false,
      },
      MIN_CLI_BUILD,
    );
    expectFailure(r);
    expect(r.message).toContain("not found");
    expect(r.message).toContain("/x/rubien-cli");
    expect(r.message).toMatch(/Install Rubien\.app/);
  });

  it("rejects timeout with a transient-hint message, not the predates message", () => {
    const r = evaluateCliProbe(
      {
        kind: "timeout",
        path: "/x/rubien-cli",
        timeoutMs: 15_000,
        envOverride: false,
      },
      MIN_CLI_BUILD,
    );
    expectFailure(r);
    expect(r.message).toContain("within 15s");
    expect(r.message).toMatch(/retry in a moment/i);
    expect(r.message).not.toMatch(/predates/i);
  });
});

describe("ensureCliCompatible", () => {
  // The gate keeps module-level state, so each test re-imports a fresh
  // module graph with a mocked probe.
  beforeEach(() => {
    vi.resetModules();
  });

  async function gateWithProbe(probe: () => unknown) {
    vi.doMock("../src/cli.js", () => ({ probeCliVersion: vi.fn(probe) }));
    const { ensureCliCompatible } = await import("../src/versionGuard.js");
    const { probeCliVersion } = await import("../src/cli.js");
    return { ensureCliCompatible, probeMock: vi.mocked(probeCliVersion) };
  }

  it("caches success — a compatible CLI is probed only once", async () => {
    const { ensureCliCompatible, probeMock } = await gateWithProbe(() => ({
      kind: "ok",
      info: { version: "9.9.9", build: 99 },
      envOverride: false,
    }));
    expect((await ensureCliCompatible()).ok).toBe(true);
    expect((await ensureCliCompatible()).ok).toBe(true);
    expect(probeMock).toHaveBeenCalledTimes(1);
  });

  it("never caches failure — re-probes each call and recovers once the CLI updates", async () => {
    let build = 18;
    const { ensureCliCompatible, probeMock } = await gateWithProbe(() => ({
      kind: "ok",
      info: { version: "x", build },
      envOverride: false,
    }));
    expect((await ensureCliCompatible()).ok).toBe(false);
    expect((await ensureCliCompatible()).ok).toBe(false);
    build = 99; // "the user updated Rubien.app mid-session"
    expect((await ensureCliCompatible()).ok).toBe(true);
    // ...and the recovery is itself cached.
    expect((await ensureCliCompatible()).ok).toBe(true);
    expect(probeMock).toHaveBeenCalledTimes(3);
  });

  it("shares one in-flight probe among concurrent callers", async () => {
    let resolveProbe!: (p: unknown) => void;
    const pending = new Promise((r) => {
      resolveProbe = r;
    });
    const { ensureCliCompatible, probeMock } = await gateWithProbe(
      () => pending,
    );
    // Both callers arrive while the probe is still pending — e.g. the stdio
    // startup log probe racing the first tool call on a cold boot.
    const a = ensureCliCompatible();
    const b = ensureCliCompatible();
    resolveProbe({
      kind: "ok",
      info: { version: "9.9.9", build: 99 },
      envOverride: false,
    });
    expect((await a).ok).toBe(true);
    expect((await b).ok).toBe(true);
    expect(probeMock).toHaveBeenCalledTimes(1);
  });
});
