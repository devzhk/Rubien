const clippingTabs = new Set();

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === 'forget-temporary-download') {
    const id = message.downloadId;
    if (!Number.isInteger(id)) {
      sendResponse({ ok: false });
      return false;
    }
    void chrome.downloads.erase({ id }).then(
      () => sendResponse({ ok: true }),
      () => sendResponse({ ok: false })
    );
    return true;
  }
  if (message?.type !== 'prepare-current-tab') return false;

  void extractTab(message)
    .then((page) => sendResponse({ ok: true, page }))
    .catch((error) => {
      const text = error instanceof Error ? error.message : String(error);
      console.error('Rubien extraction failed:', error);
      sendResponse({ ok: false, error: text });
    });
  return true;
});

async function extractTab(tab) {
  const tabId = tab?.tabId;
  if (!Number.isInteger(tabId)) throw new Error('Chrome did not provide an active tab.');
  if (clippingTabs.has(tabId)) {
    throw new Error('This tab is already being prepared for import.');
  }

  clippingTabs.add(tabId);
  // Defuddle can legitimately spend more than Chrome's 30-second extension
  // worker idle window on a client-rendered page. Chrome 110+ treats an
  // extension API call as activity, so this inexpensive call keeps the action
  // alive until extraction or its explicit timeout completes.
  const keepAliveTimer = setInterval(() => {
    void chrome.runtime.getPlatformInfo().catch(() => {});
  }, 25_000);

  try {
    const rawURL = String(tab.url || '');
    if (!/^https?:\/\//i.test(rawURL)) {
      throw new Error('Rubien can import only HTTP or HTTPS pages.');
    }

    // Chrome's built-in PDF viewer and some protected pages reject script
    // injection. The native host can still route their HTTP(S) URL through the
    // same PDF/paper pipeline as Import Reference, so extraction is an optional
    // enrichment rather than a prerequisite.
    let page;
    const directFileURL = /\.(?:pdf|md|markdown)$/i.test(new URL(rawURL).pathname);
    if (directFileURL) {
      page = {
        url: rawURL,
        title: String(tab.title || '').trim() || null,
      };
    } else {
      try {
        await chrome.scripting.executeScript({
          target: { tabId },
          files: ['dist/ClipperDefuddle.js'],
          world: 'ISOLATED',
        });

        const injection = await chrome.scripting.executeScript({
          target: { tabId },
          func: extractRubienClip,
          world: 'ISOLATED',
        });
        page = injection && injection[0] && injection[0].result;
        if (!page || typeof page !== 'object') {
          throw new Error('The page did not return an extractable document.');
        }
      } catch (extractionError) {
        console.warn('Rubien page extraction unavailable; importing by URL:', extractionError);
        page = {
          url: rawURL,
          title: String(tab.title || '').trim() || null,
        };
      }
    }

    return page;
  } finally {
    clearInterval(keepAliveTimer);
    clippingTabs.delete(tabId);
  }
}

// This function is serialized by chrome.scripting.executeScript, so it must be
// self-contained: no references to service-worker globals or imported code.
async function extractRubienClip() {
  const MAX_HTML_BYTES = 8 * 1024 * 1024;
  const encoder = new TextEncoder();

  function firstMeta(...selectors) {
    for (const selector of selectors) {
      const value = document.querySelector(selector)?.getAttribute('content')?.trim();
      if (value) return value;
    }
    return null;
  }

  function citationValues(name) {
    citationMetadata ??= collectCitationMetadata();
    return citationMetadata.get(name.toLowerCase()) || [];
  }

  function firstCitation(name) {
    return citationValues(name)[0] || null;
  }

  function absoluteURL(raw) {
    if (!raw) return null;
    try {
      const url = new URL(raw, document.URL);
      return /^https?:$/.test(url.protocol) ? url.href : null;
    } catch (_) {
      return null;
    }
  }

  function collectCitationMetadata() {
    const valuesByName = new Map();
    for (const meta of document.head?.querySelectorAll('meta[name], meta[property]') || []) {
      const key = (meta.getAttribute('name') || meta.getAttribute('property') || '')
        .toLowerCase();
      if (!key.startsWith('citation_')) continue;
      const value = meta.getAttribute('content')?.trim();
      if (!value) continue;
      const values = valuesByName.get(key) || [];
      if (values.length < 100) {
        values.push(value);
        valuesByName.set(key, values);
      }
    }
    return valuesByName;
  }

  let citationMetadata = null;

  await new Promise((resolve) => {
    let settled = false;
    let checkTimer = null;
    let postLoadTimer = null;
    let deadlineTimer = null;

    const hasEnoughContent = () => {
      const textLength = (document.body?.textContent || '').trim().length;
      const blocks = document.querySelectorAll(
        'article p, article li, main p, main li, [role="main"] p, [role="main"] li'
      ).length;
      return textLength + blocks * 50 >= 250;
    };
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(checkTimer);
      clearTimeout(postLoadTimer);
      clearTimeout(deadlineTimer);
      observer.disconnect();
      window.removeEventListener('load', onLoad);
      resolve();
    };
    const check = () => {
      checkTimer = null;
      if (hasEnoughContent()) finish();
    };
    const scheduleCheck = () => {
      if (settled || checkTimer) return;
      checkTimer = setTimeout(check, 100);
    };
    const onLoad = () => {
      if (hasEnoughContent()) {
        finish();
      } else {
        postLoadTimer = setTimeout(finish, 750);
      }
    };
    const observer = new MutationObserver(scheduleCheck);

    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      characterData: true,
    });
    window.addEventListener('load', onLoad, { once: true });
    deadlineTimer = setTimeout(finish, 10_000);

    if (hasEnoughContent()) {
      finish();
    } else if (document.readyState === 'complete') {
      postLoadTimer = setTimeout(finish, 750);
    }
  });

  if (typeof window.RubienDefuddleExtract !== 'function') {
    throw new Error('Rubien extraction bundle is unavailable. Rebuild the extension.');
  }

  const extracted = await new Promise((resolve, reject) => {
    let settled = false;
    let timeout;
    const cleanup = () => {
      clearTimeout(timeout);
      if (window.RubienDefuddleResultCallback === receiveResult) {
        delete window.RubienDefuddleResultCallback;
      }
    };
    const receiveResult = (payload) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(payload);
    };
    window.RubienDefuddleResultCallback = receiveResult;

    timeout = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error('Page extraction timed out.'));
    }, 70_000);

    try {
      window.RubienDefuddleExtract();
    } catch (error) {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    }
  });

  const contentHTML = extracted?.ok && typeof extracted.content === 'string'
    ? extracted.content.trim()
    : null;
  if (contentHTML && encoder.encode(contentHTML).byteLength > MAX_HTML_BYTES) {
    throw new Error('The extracted article is larger than Rubien’s 8 MB clip limit.');
  }

  const canonical = absoluteURL(document.querySelector('link[rel="canonical"]')?.href);
  const favicon = absoluteURL(
    document.querySelector('link[rel~="icon"]')?.href ||
    document.querySelector('link[rel="apple-touch-icon"]')?.href
  );

  return {
    url: location.href,
    canonicalURL: canonical,
    title: String(extracted?.title || document.title || '').trim() || null,
    author: String(extracted?.author || '').trim() || null,
    excerpt: String(
      extracted?.description || extracted?.excerpt ||
      firstMeta('meta[name="description"]', 'meta[property="og:description"]') || ''
    ).trim() || null,
    siteName: firstMeta('meta[property="og:site_name"]', 'meta[name="application-name"]') ||
      location.hostname,
    faviconURL: favicon,
    contentHTML,
    citation: {
      title: firstCitation('citation_title'),
      authors: citationValues('citation_author'),
      publicationDate: firstCitation('citation_publication_date') ||
        firstCitation('citation_date') || firstCitation('citation_year'),
      journalTitle: firstCitation('citation_journal_title'),
      conferenceTitle: firstCitation('citation_conference_title'),
      volume: firstCitation('citation_volume'),
      issue: firstCitation('citation_issue'),
      firstPage: firstCitation('citation_firstpage'),
      lastPage: firstCitation('citation_lastpage'),
      doi: firstCitation('citation_doi'),
      isbn: firstCitation('citation_isbn'),
      issn: firstCitation('citation_issn'),
      abstract: firstCitation('citation_abstract'),
      publisher: firstCitation('citation_publisher'),
      pdfURL: absoluteURL(firstCitation('citation_pdf_url')),
      arxivID: firstCitation('citation_arxiv_id'),
    },
  };
}
