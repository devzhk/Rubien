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
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const outfile = resolve(here, '../../Sources/Rubien/Resources/ClipperDefuddle.js');

await build({
  entryPoints: [resolve(here, 'src/clipper-defuddle.js')],
  bundle: true,
  format: 'iife',
  // macOS 15 Sequoia ships Safari 18 / WebKit 620+. Target this
  // explicitly so esbuild doesn't downlevel syntax it doesn't need to
  // (e.g. Promise.withResolvers, iterator helpers).
  target: 'safari18',
  minify: true,
  outfile,
  // Banner makes the file's purpose obvious when someone opens the raw
  // resource file in the Swift package.
  banner: {
    js: '/* Rubien clipper-defuddle bundle. Built from scripts/clipper/ — do not edit by hand. */',
  },
  logLevel: 'info',
});

console.log(`Wrote ${outfile}`);
