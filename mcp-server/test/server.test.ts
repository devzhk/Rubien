import { describe, it, expect } from "vitest";
import { buildServer } from "../src/server.js";

describe("buildServer", () => {
  it("registers the full tool catalog without error", () => {
    const server = buildServer();
    expect(server).toBeDefined();
    // The registered tools are tracked on the underlying low-level Server
    // via internal maps. We can't easily enumerate them without digging into
    // private state, so the smoke check here is "buildServer doesn't throw".
    // The tools tests below exercise individual handlers directly.
  });
});
