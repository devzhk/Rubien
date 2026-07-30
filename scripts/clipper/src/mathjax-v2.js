// MathJax v2 keeps the author-provided TeX in a sibling script element while
// the visible frame contains only generated MathML/SVG. Defuddle can encounter
// the frame before that script and then reconstruct LaTeX from MathML, which is
// necessarily lossy for operators, spacing, and equation labels. Copy the
// source onto every matching frame/container before Defuddle walks the clone.
export function rubienPreserveMathJaxV2Latex(doc) {
  if (!doc || typeof doc.querySelectorAll !== 'function') return;

  const scripts = doc.querySelectorAll(
    'script[type="math/tex"], script[type="math/tex; mode=display"]'
  );

  for (const script of scripts) {
    const latex = String(script.textContent || '').trim();
    if (!latex) continue;

    const type = String(script.getAttribute('type') || '').toLowerCase();
    const isDisplay = type.includes('mode=display');
    const scriptID = String(script.getAttribute('id') || script.id || '').trim();
    const frame =
      scriptID && typeof doc.getElementById === 'function'
        ? doc.getElementById(scriptID + '-Frame')
        : null;

    if (frame && typeof frame.setAttribute === 'function') {
      frame.setAttribute('data-latex', latex);
      const displayContainer =
        isDisplay && typeof frame.closest === 'function'
          ? frame.closest('.MathJax_Display')
          : null;
      if (displayContainer && typeof displayContainer.setAttribute === 'function') {
        displayContainer.setAttribute('data-latex', latex);
      }
    }

    // Some MathJax v2 configurations omit the usual element ID. Its rendered
    // frame is still the script's preceding sibling (occasionally wrapped by
    // `.MathJax_Display`), so annotate that path as a safe fallback.
    const preceding = script.previousElementSibling;
    if (preceding && typeof preceding.setAttribute === 'function') {
      const isRenderedFrame =
        typeof preceding.matches === 'function' &&
        preceding.matches('.MathJax, .MathJax_Display, .MathJax_SVG, .MathJax_MathML');
      if (isRenderedFrame) {
        preceding.setAttribute('data-latex', latex);
      }
    }
  }
}
