import { describe, it, expect } from "vitest";
import { MIN_CLI_BUILD, evaluateCliVersion } from "../src/versionGuard.js";

describe("evaluateCliVersion", () => {
  it("accepts a build >= MIN_CLI_BUILD", () => {
    const r = evaluateCliVersion({ version: "0.1.7", build: MIN_CLI_BUILD }, MIN_CLI_BUILD);
    expect(r.ok).toBe(true);
  });

  it("rejects build 18 because it predates the unified write surface (build 26 floor)", () => {
    const r = evaluateCliVersion({ version: "0.2.3", build: 18 }, MIN_CLI_BUILD);
    expect(r.ok).toBe(false);
    expect(r.message).toContain("build 18");
    expect(r.message).toContain(">= 26");
    expect(r.message).toMatch(/Update Rubien\.app|download a newer rubien-cli/i);
  });

  it("rejects null (no version subcommand) with the predates message", () => {
    const r = evaluateCliVersion(null, MIN_CLI_BUILD);
    expect(r.ok).toBe(false);
    expect(r.message).toMatch(/predates the 'version' command/i);
  });
});
