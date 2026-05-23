// Bridges Defuddle's parse() / parseAsync() result to the JSON contract
// that Sources/Rubien/ReaderExtraction/ReaderExtractionManager.swift expects,
// and preserves the RubienClipperDebug diagnostic channel that
// Sources/Rubien/Views/WebReaderView.swift:1725 (registration) and
// :1997 (consumer) rely on.
//
// Two delivery channels for the result:
//   1. webkit.messageHandlers.readerResult.postMessage(payload)  — canonical
//   2. return JSON.stringify(payload)                            — sync-only fallback
//      (Swift's processDefuddleJSONFallback fires 0.2s after evaluateJavaScript
//       completes if postMessage hasn't landed). Async (parseAsync) path
//       returns undefined; postMessage is the only practical channel there.
//
// We import `defuddle/full` because Notion (and similar SPAs that use
// KaTeX) emit math as raw LaTeX strings in the DOM and rely on a runtime
// renderer. Core `defuddle` extracts those strings as plain text and
// stops; `defuddle/full` includes `temml` + `mathml-to-latex` which
// convert the LaTeX into `<math>` elements at extraction time so the
// reader can render them. This costs ~400 KB of bundle size vs core;
// confirmed necessary by a smoke test against a math-heavy Notion post.

import Defuddle from 'defuddle/full';

const SOURCE = 'defuddle';
// Matches the timeout the previous obsidian-clipper bundle enforced.
// Only effective on the parseAsync path; sync `.parse()` can't be canceled.
const PARSE_TIMEOUT_MS = 45_000;

function buildPayload(result, error) {
  if (error) {
    return {
      source: SOURCE,
      ok: false,
      error: String(error && error.message ? error.message : error),
    };
  }
  const content = (result && result.content) ? result.content : '';
  return {
    source: SOURCE,
    ok: content.trim().length > 0,
    content,
    title: (result && result.title) || '',
    description: (result && result.description) || '',
    // `excerpt` is a legacy alias the Swift side falls back to when
    // `description` is absent. Defuddle 0.18.1 doesn't emit a separate
    // excerpt field, so we mirror description here.
    excerpt: (result && result.description) || '',
    author: (result && result.author) || '',
  };
}

window.RubienDefuddleExtract = function RubienDefuddleExtract() {
  // Cache once per extraction — handler refs and URL are read on every
  // phase post (extract_start, parse_async_begin, parse_async_end, exit)
  // and on result delivery. Avoids re-walking `window.webkit.messageHandlers`
  // 5–7 times per clip.
  const mh =
    (typeof window !== 'undefined' && window.webkit && window.webkit.messageHandlers) || null;
  const dbgCh = mh && mh.RubienClipperDebug;
  const resCh = mh && mh.readerResult;
  const pageURL = (typeof document !== 'undefined' && document.URL) || '';

  function debugPost(phase, detail) {
    if (!dbgCh) return;
    try {
      dbgCh.postMessage({
        phase,
        url: pageURL,
        detail: detail == null ? '' : String(detail),
      });
    } catch (_) {}
  }

  function postResult(payload) {
    if (resCh) {
      try { resCh.postMessage(payload); } catch (_) {}
    }
    return JSON.stringify(payload);
  }

  // Idempotency guard: protects against double-injection of this IIFE,
  // duplicate WKScriptMessageHandler delivery, and future code changes
  // that might race the Promise.race below. Mirrors Swift's
  // `defuddleResultHandled` (ReaderExtractionManager.swift:27).
  let delivered = false;
  function deliver(payload) {
    if (delivered) return JSON.stringify(payload);
    delivered = true;
    return postResult(payload);
  }

  function exitError(prefix, err) {
    debugPost('rubien_defuddle_exit', prefix + (err && err.message));
    return deliver(buildPayload(null, err));
  }

  debugPost('rubien_defuddle_extract_start');
  let inst;
  try {
    inst = new Defuddle(document, { url: pageURL });
  } catch (err) {
    return exitError('ctor_error: ', err);
  }

  if (typeof inst.parseAsync === 'function') {
    // Async path: postMessage is the only practical delivery channel.
    // evaluateJavaScript will see `undefined` as the return value;
    // Swift's processDefuddleJSONFallback (0.2 s after evaluateJavaScript's
    // callback) checks `defuddleResultHandled` first, so it only triggers
    // if postMessage hasn't landed yet — typical extraction finishes in
    // well under 200 ms, so postMessage almost always wins the race.
    debugPost('rubien_defuddle_parse_async_begin');
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(
        () => reject(new Error('parse_timeout_' + PARSE_TIMEOUT_MS + 'ms')),
        PARSE_TIMEOUT_MS
      );
    });
    Promise.race([inst.parseAsync(), timeout])
      .then((result) => {
        clearTimeout(timer);
        debugPost('rubien_defuddle_parse_async_end');
        const payload = buildPayload(result, null);
        debugPost('rubien_defuddle_exit', 'ok=' + payload.ok);
        deliver(payload);
      })
      .catch((err) => {
        clearTimeout(timer);
        exitError('error: ', err);
      });
    return undefined;
  }

  try {
    const result = inst.parse();
    const payload = buildPayload(result, null);
    debugPost('rubien_defuddle_exit', 'ok=' + payload.ok);
    return deliver(payload);
  } catch (err) {
    return exitError('error: ', err);
  }
};
