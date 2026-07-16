import { describe, expect, it } from "vitest";
import { safeExternalURL, safeFetchURL } from "../lib/url";

describe("safeExternalURL", () => {
  it("allows http, https, and mailto", () => {
    expect(safeExternalURL("https://example.com/a")).toBe("https://example.com/a");
    expect(safeExternalURL("http://example.com")).toBe("http://example.com/");
    expect(safeExternalURL("mailto:a@example.com")).toBe("mailto:a@example.com");
  });

  it("assumes https for a scheme-less value", () => {
    expect(safeExternalURL("example.com/path")).toBe("https://example.com/path");
  });

  it("rejects dangerous schemes", () => {
    expect(safeExternalURL("javascript:alert(1)")).toBeUndefined();
    expect(safeExternalURL("  javascript:alert(1)  ")).toBeUndefined();
    expect(safeExternalURL("data:text/html,<script>alert(1)</script>")).toBeUndefined();
    expect(safeExternalURL("file:///etc/passwd")).toBeUndefined();
  });

  it("returns undefined for empty input", () => {
    expect(safeExternalURL(undefined)).toBeUndefined();
    expect(safeExternalURL("")).toBeUndefined();
    expect(safeExternalURL("   ")).toBeUndefined();
  });
});

describe("safeFetchURL", () => {
  it("allows only http and https with an explicit scheme", () => {
    expect(safeFetchURL("https://example.com/x")).toBe("https://example.com/x");
    expect(safeFetchURL("http://example.com")).toBe("http://example.com/");
  });

  it("rejects mailto, other schemes, and scheme-less values", () => {
    expect(safeFetchURL("mailto:a@example.com")).toBeUndefined();
    expect(safeFetchURL("javascript:alert(1)")).toBeUndefined();
    expect(safeFetchURL("file:///etc/passwd")).toBeUndefined();
    expect(safeFetchURL("example.com/x")).toBeUndefined();
  });
});
