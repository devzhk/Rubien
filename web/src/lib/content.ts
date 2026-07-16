import DOMPurify from "dompurify";
import { marked } from "marked";
import { ReferenceRecord } from "./types";

marked.use({
  gfm: true,
  breaks: false
});

// DOMPurify keeps `target="_blank"` but does not add `rel`, leaving captured
// content vulnerable to reverse tabnabbing (the opened page gets a live
// `window.opener`). Force `rel="noopener noreferrer"` on any link that opens
// a new context.
DOMPurify.addHook("afterSanitizeAttributes", (node) => {
  if (node instanceof Element && node.tagName === "A" && node.hasAttribute("target")) {
    node.setAttribute("rel", "noopener noreferrer");
  }
});

export function renderStoredContent(reference: ReferenceRecord): string {
  const content = reference.webContent ?? "";
  const format = reference.webContentFormat ?? (reference.referenceType === "Markdown" ? "markdown" : "html");
  if (!content.trim()) return "";
  if (format === "markdown") {
    return DOMPurify.sanitize(marked.parse(content, { async: false }) as string);
  }
  if (format === "text") {
    return DOMPurify.sanitize(`<pre>${escapeHTML(content)}</pre>`);
  }
  return DOMPurify.sanitize(content);
}

function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;");
}
