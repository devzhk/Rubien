const NATIVE_HOST_NAME = 'com.rubien.browser_clipper';
const PROTOCOL_VERSION = 4;

let nativePort = null;
let confirmationID = null;
let previewPDFURL = null;
let previewOffersPDF = false;
let pendingDownloadID = null;
let confirmationAwaitingHost = false;
let finished = false;
let openingRubien = false;
let resultDestination = null;

const views = ['loading-view', 'preview-view', 'result-view', 'error-view'];
const actionBars = ['preview-actions', 'result-actions', 'error-actions'];

document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('cancel-button').addEventListener('click', closePopup);
  document.getElementById('confirm-button').addEventListener('click', confirmImport);
  document.getElementById('open-button').addEventListener('click', openInRubien);
  document.getElementById('close-button').addEventListener('click', closePopup);
  document.getElementById('retry-button').addEventListener('click', () => location.reload());
  void prepareImport();
});

window.addEventListener('unload', () => {
  if (nativePort) nativePort.disconnect();
  void cleanupPDFDownload();
});

async function prepareImport() {
  try {
    showOnly('loading-view');
    setLoading('Reading the current tab…', 'Rubien is preparing an import preview.');

    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab || !Number.isInteger(tab.id)) {
      throw new Error('Chrome did not provide an active tab.');
    }

    const extracted = await chrome.runtime.sendMessage({
      type: 'prepare-current-tab',
      tabId: tab.id,
      url: tab.url || '',
      title: tab.title || '',
    });
    if (!extracted?.ok || !extracted.page) {
      throw new Error(extracted?.error || 'The current tab could not be read.');
    }

    let page = extracted.page;
    try {
      page = await stageDirectFileWithChrome(page);
    } catch (error) {
      console.warn('Authenticated direct-file download failed; Rubien will try the URL:', error);
    }

    setLoading('Resolving with Rubien…', 'Nothing has been saved yet.');
    nativePort = connectNativeHost();
    nativePort.postMessage({
      version: PROTOCOL_VERSION,
      command: 'preview',
      page,
    });
  } catch (error) {
    showError(error instanceof Error ? error.message : String(error));
  }
}

function handleNativeResponse(response) {
  confirmationAwaitingHost = false;
  if (!response?.ok) {
    const message = response?.error?.message || 'Rubien could not prepare this import.';
    if (openingRubien) {
      showOpenError(message);
    } else {
      showError(message);
    }
    return;
  }
  if (response.preview) {
    confirmationID = response.preview.confirmationID;
    renderPreview(response.preview);
    return;
  }
  if (response.opened) {
    openingRubien = false;
    closePopup();
    return;
  }
  if (response.result) {
    finished = true;
    const port = nativePort;
    nativePort = null;
    if (port) port.disconnect();
    void cleanupPDFDownload();
    renderResult(response);
    return;
  }
  showError('Rubien returned an incomplete response.');
}

async function confirmImport() {
  if (!nativePort || !confirmationID) return;
  const shouldDownloadPDF = previewOffersPDF && document.getElementById('download-pdf-checkbox').checked;
  document.getElementById('confirm-button').disabled = true;
  document.getElementById('cancel-button').disabled = true;
  showOnly('loading-view');
  setLoading(
    shouldDownloadPDF && previewPDFURL ? 'Downloading the paper PDF…' : 'Importing into Rubien…',
    shouldDownloadPDF && previewPDFURL
      ? 'Chrome is using your signed-in publisher session.'
      : 'Committing the preview you confirmed.'
  );

  let downloadedPDFPath = null;
  if (shouldDownloadPDF && previewPDFURL) {
    try {
      const downloaded = await downloadPDFWithChrome(previewPDFURL, confirmationID);
      pendingDownloadID = downloaded.id;
      downloadedPDFPath = downloaded.filename;
      setLoading('Importing into Rubien…', 'Attaching the downloaded PDF.');
    } catch (error) {
      console.warn('Authenticated PDF download failed; Rubien will try its normal downloader:', error);
      setLoading('Importing into Rubien…', 'Chrome could not fetch the PDF; Rubien is trying its normal source.');
    }
  }

  confirmationAwaitingHost = true;
  try {
    nativePort.postMessage({
      version: PROTOCOL_VERSION,
      command: 'confirm',
      confirmationID,
      downloadedPDFPath,
      downloadPDF: shouldDownloadPDF,
    });
  } catch (error) {
    confirmationAwaitingHost = false;
    showError(error instanceof Error ? error.message : String(error));
  }
}

function renderPreview(preview) {
  const kindLabels = {
    paper: 'Paper',
    pdf: 'PDF',
    markdown: 'Markdown',
    webpage: 'Web page',
  };
  setText('kind-badge', kindLabels[preview.kind] || 'Reference');
  setText('preview-title', preview.title || 'Untitled reference');
  setOptionalRow('authors-row', 'preview-authors', (preview.authors || []).join(', '));
  setOptionalRow('year-row', 'preview-year', preview.year ? String(preview.year) : '');
  setOptionalRow('container-row', 'preview-container', preview.containerTitle || '');
  setOptionalRow('source-row', 'preview-source', preview.sourceURL || '');
  setText('preview-message', preview.message || 'Review this reference before importing.');
  previewPDFURL = preview.willDownloadPDF && /^https:\/\//i.test(preview.pdfDownloadURL || '')
    ? preview.pdfDownloadURL
    : null;
  previewOffersPDF = preview.willDownloadPDF === true;
  document.getElementById('download-pdf-checkbox').checked = true;
  toggleHidden('pdf-option', !previewOffersPDF);
  setText('capture-badge', 'Page content captured');
  toggleHidden('capture-badge', !preview.hasCapturedContent);
  toggleHidden('review-notice', !preview.willQueueForReview);
  showOnly('preview-view', 'preview-actions');
}

function renderResult(response) {
  const queued = response.result === 'queued';
  const existing = response.result === 'existing';
  setText('result-mark', queued ? '?' : (existing ? '=' : '✓'));
  setText('result-title', queued ? 'Queued for review' : (existing ? 'Already in Rubien' : 'Imported'));
  const title = response.title || 'The reference is now available in Rubien.';
  setText('result-detail', response.message ? `${title} — ${response.message}` : title);
  const referenceID = Number.isSafeInteger(response.referenceID) && response.referenceID > 0
    ? response.referenceID
    : null;
  const intakeID = Number.isSafeInteger(response.intakeID) && response.intakeID > 0
    ? response.intakeID
    : null;
  resultDestination = referenceID !== null
    ? { referenceID }
    : (intakeID !== null ? { intakeID } : null);
  const openButton = document.getElementById('open-button');
  openButton.disabled = false;
  openButton.textContent = resultDestination
    ? (queued ? 'Review in Rubien' : 'Open in Rubien')
    : 'Done';
  toggleHidden('result-open-error', true);
  showOnly('result-view', 'result-actions');
}

function connectNativeHost() {
  const port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
  port.onMessage.addListener(handleNativeResponse);
  port.onDisconnect.addListener(() => {
    const message = chrome.runtime.lastError?.message;
    if (nativePort === port) nativePort = null;
    if (openingRubien) {
      openingRubien = false;
      confirmationAwaitingHost = false;
      showOpenError(message || 'Rubien closed the connection before opening this item.');
    } else if (!finished && message) {
      confirmationAwaitingHost = false;
      showError(message);
    }
  });
  return port;
}

function openInRubien() {
  if (!resultDestination) {
    closePopup();
    return;
  }

  const openButton = document.getElementById('open-button');
  openButton.disabled = true;
  openButton.textContent = 'Opening Rubien…';
  openingRubien = true;

  try {
    if (!nativePort) nativePort = connectNativeHost();
    nativePort.postMessage({
      version: PROTOCOL_VERSION,
      command: 'open',
      ...resultDestination,
    });
  } catch (error) {
    openingRubien = false;
    showOpenError(error instanceof Error ? error.message : String(error));
  }
}

function showOpenError(message) {
  openingRubien = false;
  finished = true;
  const port = nativePort;
  nativePort = null;
  if (port) port.disconnect();
  setText('result-open-error', message);
  toggleHidden('result-open-error', false);
  const openButton = document.getElementById('open-button');
  openButton.disabled = false;
  openButton.textContent = resultDestination?.intakeID
    ? 'Review in Rubien'
    : 'Open in Rubien';
  showOnly('result-view', 'result-actions');
}

function showError(message) {
  finished = true;
  openingRubien = false;
  const port = nativePort;
  nativePort = null;
  if (port) port.disconnect();
  void cleanupPDFDownload();
  setText('error-detail', message);
  showOnly('error-view', 'error-actions');
}

function setLoading(title, detail) {
  setText('loading-title', title);
  setText('loading-detail', detail);
}

function setOptionalRow(rowID, valueID, value) {
  setText(valueID, value);
  toggleHidden(rowID, !value);
}

function setText(id, value) {
  document.getElementById(id).textContent = String(value || '');
}

function toggleHidden(id, hidden) {
  document.getElementById(id).classList.toggle('hidden', hidden);
}

function showOnly(viewID, actionsID = null) {
  for (const id of views) toggleHidden(id, id !== viewID);
  for (const id of actionBars) toggleHidden(id, id !== actionsID);
}

function closePopup() {
  finished = true;
  openingRubien = false;
  if (nativePort) nativePort.disconnect();
  nativePort = null;
  void cleanupPDFDownload();
  window.close();
}

async function stageDirectFileWithChrome(page) {
  const parsed = new URL(page?.url || '');
  const match = parsed.pathname.match(/\.(pdf|md|markdown)$/i);
  if (!match) return page;

  setLoading('Downloading the source…', 'Chrome is using your signed-in session.');
  const extension = match[1].toLowerCase();
  const token = crypto.randomUUID().toLowerCase();
  const downloaded = await downloadWithChrome(
    parsed,
    `Rubien/rubien-preview-${token}.${extension}`,
    true
  );
  return {
    ...page,
    browserDownloadedFilePath: downloaded.filename,
    browserDownloadToken: token,
  };
}

async function downloadPDFWithChrome(url, importConfirmationID) {
  const parsed = new URL(url);
  return downloadWithChrome(
    parsed,
    `Rubien/rubien-${String(importConfirmationID).toLowerCase()}.pdf`,
    false
  );
}

async function downloadWithChrome(parsed, filename, allowHTTP) {
  if (parsed.protocol !== 'https:' && !(allowHTTP && parsed.protocol === 'http:')) {
    throw new Error('Rubien accepts only HTTPS publisher PDF downloads.');
  }

  const id = await chrome.downloads.download({
    url: parsed.href,
    filename,
    conflictAction: 'overwrite',
    saveAs: false,
  });
  pendingDownloadID = id;
  const item = await waitForDownload(id);
  if (!item.filename) throw new Error('Chrome did not expose the downloaded PDF path.');
  return { id, filename: item.filename };
}

async function waitForDownload(id) {
  await new Promise((resolve, reject) => {
    let settled = false;
    const timeout = setTimeout(() => {
      finish(() => reject(new Error('The PDF download timed out.')));
    }, 120_000);
    const finish = (callback) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      chrome.downloads.onChanged.removeListener(onChanged);
      callback();
    };
    const onChanged = (delta) => {
      if (delta.id !== id || !delta.state) return;
      if (delta.state.current === 'complete') finish(resolve);
      if (delta.state.current === 'interrupted') {
        finish(() => reject(new Error(delta.error?.current || 'Chrome interrupted the PDF download.')));
      }
    };
    chrome.downloads.onChanged.addListener(onChanged);
    void chrome.downloads.search({ id }).then(([current]) => {
      if (current?.state === 'complete') finish(resolve);
      if (current?.state === 'interrupted') {
        finish(() => reject(new Error(current.error || 'Chrome interrupted the PDF download.')));
      }
    }, (error) => finish(() => reject(error)));
  });

  const [completed] = await chrome.downloads.search({ id });
  if (!completed || completed.state !== 'complete') {
    throw new Error('Chrome did not finish the PDF download.');
  }
  return completed;
}

async function cleanupPDFDownload() {
  const id = pendingDownloadID;
  pendingDownloadID = null;
  if (!Number.isInteger(id)) return;
  if (confirmationAwaitingHost) {
    // The native host owns file deletion after it has copied the confirmed
    // download. Ask the persistent worker to remove only Chrome's history
    // record so unloading this popup cannot race the native file read.
    try {
      await chrome.runtime.sendMessage({
        type: 'forget-temporary-download',
        downloadId: id,
      });
    } catch (_) {
      // History cleanup is best effort; the native host still owns the file.
    }
    return;
  }
  try {
    await chrome.downloads.cancel(id);
  } catch (_) {
    // Completed and already-cancelled downloads do not need cancellation.
  }
  try {
    await chrome.downloads.removeFile(id);
  } catch (_) {
    // A failed or externally removed download has no temporary file to clean.
  }
  try {
    await chrome.downloads.erase({ id });
  } catch (_) {
    // Import success must not depend on pruning Chrome's downloads history.
  }
}
