// Bundles src/clipper-defuddle.js (which imports defuddle/full) into a
// single IIFE-wrapped script that WKWebView can load via
// evaluateJavaScript. Output overwrites Sources/Rubien/Resources/ClipperDefuddle.js.
//
// To upgrade Defuddle:
//   1. cd scripts/clipper && npm update defuddle
//   2. npm run build
//   3. Commit package.json, package-lock.json, and the regenerated
//      Sources/Rubien/Resources/ClipperDefuddle.js together.

import { build } from 'esbuild';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const outfile = resolve(here, '../../Sources/Rubien/Resources/ClipperDefuddle.js');
const browserOutfile = resolve(here, '../../BrowserExtension/dist/ClipperDefuddle.js');

await build({
  entryPoints: [resolve(here, 'src/clipper-defuddle.js')],
  bundle: true,
  format: 'iife',
  // The macOS 14.4 Sonoma deployment floor ships Safari 17.4 (WebKit 618).
  // Target that WKWebView explicitly so esbuild down-levels any syntax newer
  // than 17.4 (e.g. iterator helpers) that Defuddle or its deps might emit —
  // a Safari-18 target would let such syntax reach a 14.x WKWebView and throw.
  target: 'safari17.4',
  minify: true,
  outfile,
  // Banner makes the file's purpose obvious when someone opens the raw
  // resource file in the Swift package.
  banner: {
    js: '/* Rubien clipper-defuddle bundle. Built from scripts/clipper/ — do not edit by hand. */',
  },
  logLevel: 'info',
});

// Some bundled dependency string literals contain source lines with trailing
// spaces. Normalize generated output so `git diff --check` remains useful and
// repeated builds stay byte-for-byte stable.
const bundledSource = await readFile(outfile, 'utf8');
const normalizedSource = bundledSource
  .split('\n')
  .map((line) => line.trimEnd())
  .join('\n');
if (normalizedSource !== bundledSource) {
  await writeFile(outfile, normalizedSource);
}

await mkdir(dirname(browserOutfile), { recursive: true });
await copyFile(outfile, browserOutfile);

console.log(`Wrote ${outfile}`);
console.log(`Wrote ${browserOutfile}`);
