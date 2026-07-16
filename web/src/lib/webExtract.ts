import { Readability, isProbablyReaderable } from "@mozilla/readability";
import { emptyReference, id, parseAuthors } from "./model";
import { ReferenceRecord } from "./types";

export interface ExtractedWebReference {
  reference: ReferenceRecord;
  readerable: boolean;
}

export async function fetchReadableURL(url: string): Promise<ExtractedWebReference> {
  const response = await fetch(url, {
    headers: { Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }
  });
  if (!response.ok) throw new Error(`Could not fetch ${url}: HTTP ${response.status}`);
  const contentType = response.headers.get("content-type") ?? "";
  if (contentType && !contentType.includes("html") && !contentType.includes("xml") && !contentType.includes("text/plain")) {
    throw new Error(`Fetched ${url}, but it is ${contentType}, not readable HTML.`);
  }
  return extractReadableHTML(await response.text(), url);
}

export function extractReadableHTML(html: string, sourceUrl?: string, fallbackTitle = "Captured web page"): ExtractedWebReference {
  const document = new DOMParser().parseFromString(html, "text/html");
  ensureBaseURL(document, sourceUrl);
  const readerable = isProbablyReaderable(document.cloneNode(true) as Document, {
    minContentLength: 120
  });
  const article = new Readability(document.cloneNode(true) as Document, {
    keepClasses: false
  }).parse();
  const title =
    article?.title?.trim() ||
    document.querySelector("meta[property='og:title']")?.getAttribute("content")?.trim() ||
    document.querySelector("title")?.textContent?.trim() ||
    fallbackTitle;
  const content = article?.content?.trim() || document.body?.innerHTML || html;
  const text = article?.textContent || document.body?.textContent || html;
  const siteName =
    article?.siteName?.trim() ||
    document.querySelector("meta[property='og:site_name']")?.getAttribute("content")?.trim() ||
    hostname(sourceUrl);

  return {
    readerable,
    reference: emptyReference({
      id: id("ref"),
      title,
      authors: article?.byline ? parseAuthors(article.byline) : [],
      url: sourceUrl,
      abstract: substantialExcerpt(article?.excerpt, text),
      webContent: content,
      webContentFormat: "html",
      siteName,
      referenceType: "Web Page",
      metadataSource: "web",
      verificationStatus: readerable ? "candidate" : "seedOnly"
    })
  };
}

function ensureBaseURL(document: Document, sourceUrl?: string): void {
  if (!sourceUrl || document.querySelector("base")) return;
  const base = document.createElement("base");
  base.href = sourceUrl;
  document.head.prepend(base);
}

function summarize(value: string): string | undefined {
  const summary = value.replace(/\s+/g, " ").trim().slice(0, 360);
  return summary || undefined;
}

function substantialExcerpt(excerpt: string | null | undefined, text: string): string | undefined {
  const trimmed = excerpt?.replace(/\s+/g, " ").trim();
  if (trimmed && trimmed.length >= 80) return trimmed.slice(0, 360);
  return summarize(text);
}

function hostname(value?: string): string | undefined {
  try {
    return value ? new URL(value).hostname : undefined;
  } catch {
    return undefined;
  }
}
