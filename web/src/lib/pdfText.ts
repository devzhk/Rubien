import * as pdfjs from "pdfjs-dist";
import workerUrl from "pdfjs-dist/build/pdf.worker.mjs?url";
import { ExtractedPDFPage } from "./pdfSearch";

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;

export async function extractPDFText(blob: Blob): Promise<ExtractedPDFPage[]> {
  const data = new Uint8Array(await blob.arrayBuffer());
  const loadingTask = pdfjs.getDocument({ data });
  const document = await loadingTask.promise;
  const pages: ExtractedPDFPage[] = [];
  try {
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const page = await document.getPage(pageNumber);
      const content = await page.getTextContent();
      const text = content.items
        .map((item) => ("str" in item ? item.str : ""))
        .filter(Boolean)
        .join(" ")
        .replace(/\s+/g, " ")
        .trim();
      pages.push({ pageNumber, text });
    }
  } finally {
    await document.cleanup();
    await loadingTask.destroy();
  }
  return pages;
}
