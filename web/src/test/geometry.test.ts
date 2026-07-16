import { describe, expect, it } from "vitest";
import { normalizedRectFromPoints, rectToPercentStyle } from "../lib/geometry";

describe("PDF annotation geometry", () => {
  it("normalizes drag rectangles regardless of drag direction", () => {
    const rect = normalizedRectFromPoints({ x: 300, y: 200 }, { x: 100, y: 50 }, { width: 400, height: 300 });
    expect(rect).toEqual({
      x: 0.25,
      y: 1 / 6,
      width: 0.5,
      height: 0.5
    });
  });

  it("converts normalized rectangles to percent overlay styles", () => {
    expect(rectToPercentStyle({ x: 0.1, y: 0.2, width: 0.3, height: 0.4 })).toEqual({
      left: "10%",
      top: "20%",
      width: "30%",
      height: "40%"
    });
  });
});
