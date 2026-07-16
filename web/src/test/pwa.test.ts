import { describe, expect, it } from "vitest";
import { shouldRegisterServiceWorker } from "../lib/pwa";

describe("PWA service worker registration", () => {
  it("registers only in production when service workers are supported", () => {
    expect(shouldRegisterServiceWorker(true, true)).toBe(true);
    expect(shouldRegisterServiceWorker(false, true)).toBe(false);
    expect(shouldRegisterServiceWorker(true, false)).toBe(false);
  });
});
