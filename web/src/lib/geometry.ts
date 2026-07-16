import { AnnotationRect } from "./types";

export function normalizedRectFromPoints(
  start: { x: number; y: number },
  end: { x: number; y: number },
  bounds: { width: number; height: number }
): AnnotationRect | undefined {
  if (bounds.width <= 0 || bounds.height <= 0) return undefined;
  const left = Math.max(0, Math.min(start.x, end.x));
  const top = Math.max(0, Math.min(start.y, end.y));
  const right = Math.min(bounds.width, Math.max(start.x, end.x));
  const bottom = Math.min(bounds.height, Math.max(start.y, end.y));
  const width = right - left;
  const height = bottom - top;
  if (width < 3 || height < 3) return undefined;
  return {
    x: clamp01(left / bounds.width),
    y: clamp01(top / bounds.height),
    width: clamp01(width / bounds.width),
    height: clamp01(height / bounds.height)
  };
}

export function rectToPercentStyle(rect: AnnotationRect): Record<string, string> {
  return {
    left: `${rect.x * 100}%`,
    top: `${rect.y * 100}%`,
    width: `${rect.width * 100}%`,
    height: `${rect.height * 100}%`
  };
}

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}
