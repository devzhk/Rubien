import * as esbuild from 'esbuild'
import { readFileSync, writeFileSync, mkdirSync } from 'fs'
import { dirname, resolve, basename } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
// The Mac app's resource bundle — both the output HTML and the vendored KaTeX
// assets live here (same outDir pattern as scripts/note-editor/build.mjs).
const resourcesDir = resolve(__dirname, '../../Sources/Rubien/Resources')

mkdirSync(resourcesDir, { recursive: true })

// --- 1. Bundle the renderer (chat.js → one IIFE JS string + one CSS string) ---

const result = await esbuild.build({
  entryPoints: [resolve(__dirname, 'src/chat.js')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari16'],
  write: false,
  loader: { '.css': 'css' },
  outdir: 'out',
})

let bundleJS = ''
let bundleCSS = ''
for (const file of result.outputFiles) {
  if (file.path.endsWith('.js')) bundleJS = file.text
  else if (file.path.endsWith('.css')) bundleCSS = file.text
}

// --- 2. KaTeX head injection (vendored assets, fonts inlined as data URIs) -----
// Port of WebReaderView.inlineKaTeXFontsAsDataURIs / bundledKaTeXHeadInjection:
// rewrite url(KaTeX_*.woff2) → url(data:font/woff2;base64,…) so rendering is
// offline with no custom scheme handler and byte-identical to the web reader.

function inlineKaTeXFontsAsDataURIs(css) {
  const pattern = /url\(\s*["']?([^"')]+\.woff2)["']?\s*\)/gi
  return css.replace(pattern, (full, fileRel) => {
    const filename = basename(fileRel)
    try {
      const data = readFileSync(resolve(resourcesDir, filename))
      return `url(data:font/woff2;base64,${data.toString('base64')})`
    } catch (_) {
      return full // unknown filename — leave untouched (KaTeX degrades gracefully)
    }
  })
}

// Escape `</script` so third-party minified JS can't break out of the inline
// <script> element (equivalent inside JS string/regex literals — the only place
// the sequence legitimately appears in minified code).
function inlineScript(js) {
  return js.replace(/<\/script/gi, '<\\/script')
}

const rawKaTeXCSS = readFileSync(resolve(resourcesDir, 'katex.min.css'), 'utf-8')
const katexCSS = inlineKaTeXFontsAsDataURIs(rawKaTeXCSS)
const katexJS = readFileSync(resolve(resourcesDir, 'katex.min.js'), 'utf-8')
const autoRenderJS = readFileSync(resolve(resourcesDir, 'auto-render.min.js'), 'utf-8')

// --- 3. Compose the self-contained HTML --------------------------------------
// Strict CSP: everything is inline, no remote origin exists anywhere. `data:` is
// permitted only for img/font (the inlined woff2); connect-src 'none' makes the
// page incapable of any network fetch (XHR/fetch/WebSocket/EventSource).

const CSP = [
  "default-src 'none'",
  "img-src data:",
  "font-src data:",
  "style-src 'unsafe-inline'",
  "script-src 'unsafe-inline'",
  "connect-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join('; ')

const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${CSP}">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>Rubien Chat</title>
<style>${katexCSS}</style>
<script>${inlineScript(katexJS)}</script>
<script>${inlineScript(autoRenderJS)}</script>
<style>${bundleCSS}</style>
</head>
<body>
<div id="transcript"></div>
<script>${inlineScript(bundleJS)}</script>
</body>
</html>`

const outPath = resolve(resourcesDir, 'ChatTranscript.html')
writeFileSync(outPath, html, 'utf-8')

const sizeKB = (Buffer.byteLength(html, 'utf-8') / 1024).toFixed(1)
console.log(`✅ ChatTranscript.html built → ${outPath} (${sizeKB} KB)`)
