import DOMPurify from "dompurify";
import { marked } from "marked";
import { ReferenceRecord } from "./types";

marked.use({
  gfm: true,
  breaks: false
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
