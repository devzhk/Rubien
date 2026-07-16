import react from "@vitejs/plugin-react";
import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";

// Defense-in-depth for the HTML-injection paths (rendered markdown, captured
// web content). DOMPurify is the primary barrier; this CSP contains any
// bypass. `connect-src`/`img-src` allow https so remote metadata fetches and
// captured-page images still work; `worker-src blob:` covers the pdf.js worker.
const CONTENT_SECURITY_POLICY = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data:",
  "connect-src 'self' https:",
  "worker-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'none'",
  "frame-ancestors 'none'"
].join("; ");

// Injected only into the production build. In dev, @vitejs/plugin-react adds an
// inline react-refresh preamble that `script-src 'self'` would block, so the
// strict policy must not apply to the dev server.
function contentSecurityPolicy(): Plugin {
  return {
    name: "rubien-csp",
    apply: "build",
    transformIndexHtml() {
      return [
        {
          tag: "meta",
          attrs: { "http-equiv": "Content-Security-Policy", content: CONTENT_SECURITY_POLICY },
          injectTo: "head-prepend"
        }
      ];
    }
  };
}

export default defineConfig({
  plugins: [react(), contentSecurityPolicy()],
  test: {
    environment: "jsdom",
    globals: true
  }
});
