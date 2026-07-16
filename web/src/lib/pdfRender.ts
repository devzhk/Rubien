import * as pdfjs from "pdfjs-dist";
import type { RenderTask } from "pdfjs-dist";
import workerUrl from "pdfjs-dist/build/pdf.worker.mjs?url";

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;

export interface RenderedPDFPage {
  pageNumber: number;
  pageCount: number;
  width: number;
  height: number;
}

export interface RenderPDFOptions {
  // Reports the live RenderTask so the caller can `.cancel()` it (e.g. on
  // unmount or a rapid page switch). pdf.js throws if two renders touch the
  // same canvas concurrently, so cancellation is how callers stay serialized.
  onRenderTask?: (task: RenderTask) => void;
}

export function isRenderCancelled(error: unknown): boolean {
  return error instanceof Error && error.name === "RenderingCancelledException";
}

export async function renderPDFPage(
  blob: Blob,
  requestedPage: number,
  canvas: HTMLCanvasElement,
  options: RenderPDFOptions = {}
): Promise<RenderedPDFPage> {
  const data = new Uint8Array(await blob.arrayBuffer());
  const loadingTask = pdfjs.getDocument({ data });
  const document = await loadingTask.promise;
  try {
    const pageNumber = Math.max(1, Math.min(requestedPage, document.numPages));
    const page = await document.getPage(pageNumber);
    const baseViewport = page.getViewport({ scale: 1 });
    const maxWidth = Math.max(320, canvas.parentElement?.clientWidth ?? 760);
    const cssScale = Math.min(maxWidth / baseViewport.width, 1.65);
    const viewport = page.getViewport({ scale: cssScale });
    const pixelRatio = window.devicePixelRatio || 1;
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Canvas rendering is not available in this browser.");

    canvas.width = Math.floor(viewport.width * pixelRatio);
    canvas.height = Math.floor(viewport.height * pixelRatio);
    canvas.style.width = `${viewport.width}px`;
    canvas.style.height = `${viewport.height}px`;

    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    context.clearRect(0, 0, viewport.width, viewport.height);
    const renderTask = page.render({ canvas, canvasContext: context, viewport });
    options.onRenderTask?.(renderTask);
    await renderTask.promise;
    return {
      pageNumber,
      pageCount: document.numPages,
      width: viewport.width,
      height: viewport.height
    };
  } finally {
    await document.cleanup();
    await loadingTask.destroy();
  }
}
