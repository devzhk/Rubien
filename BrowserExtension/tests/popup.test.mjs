import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const popupSource = await readFile(
  new URL('../popup.js', import.meta.url),
  'utf8'
);

function makeElement() {
  const classes = new Set();
  return {
    checked: false,
    disabled: false,
    textContent: '',
    classList: {
      toggle(name, force) {
        if (force === true) classes.add(name);
        else if (force === false) classes.delete(name);
        else if (classes.has(name)) classes.delete(name);
        else classes.add(name);
      },
      contains(name) { return classes.has(name); },
    },
    addEventListener() {},
  };
}

test('result action opens imported references and queued reviews in Rubien', () => {
  const elements = new Map();
  const messages = [];
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, makeElement());
    return elements.get(id);
  };
  const context = vm.createContext({
    URL,
    clearTimeout,
    console,
    setTimeout,
    document: {
      addEventListener() {},
      getElementById: element,
    },
    window: { addEventListener() {}, close() {} },
    chrome: {},
  });
  vm.runInContext(popupSource, context);
  vm.runInContext(`
    nativePort = {
      postMessage(message) { globalThis.openMessage = message; },
      disconnect() {},
    };
  `, context);

  vm.runInContext(`renderResult({
    result: 'created', referenceID: 42, title: 'A paper'
  }); openInRubien();`, context);
  messages.push(structuredClone(context.openMessage));
  assert.equal(element('open-button').textContent, 'Opening Rubien…');

  vm.runInContext(`renderResult({
    result: 'queued', intakeID: 73, title: 'Needs review'
  }); openInRubien();`, context);
  messages.push(structuredClone(context.openMessage));

  assert.deepEqual(messages, [
    {
      version: 4,
      command: 'open',
      referenceID: 42,
    },
    {
      version: 4,
      command: 'open',
      intakeID: 73,
    },
  ]);
  assert.equal(element('open-button').textContent, 'Opening Rubien…');
});

test('successful open acknowledgement closes the result popup', () => {
  const elements = new Map();
  let closed = false;
  let disconnected = 0;
  const context = vm.createContext({
    URL,
    clearTimeout,
    console,
    setTimeout,
    document: {
      addEventListener() {},
      getElementById(id) {
        if (!elements.has(id)) elements.set(id, makeElement());
        return elements.get(id);
      },
    },
    window: {
      addEventListener() {},
      close() { closed = true; },
    },
    disconnected() { disconnected += 1; },
    chrome: {},
  });
  vm.runInContext(popupSource, context);
  vm.runInContext(`
    nativePort = {
      postMessage() {},
      disconnect() { globalThis.disconnected(); },
    };
    renderResult({ result: 'created', referenceID: 42, title: 'A paper' });
    openInRubien();
    handleNativeResponse({ ok: true, opened: true });
  `, context);

  assert.equal(closed, true);
  assert.equal(disconnected, 1);
});

test('open failure preserves the import result and supports retry', () => {
  const elements = new Map();
  const retryMessages = [];
  let disconnectListener;
  const retryPort = {
    onMessage: { addListener() {} },
    onDisconnect: { addListener(listener) { disconnectListener = listener; } },
    postMessage(message) { retryMessages.push(structuredClone(message)); },
    disconnect() {},
  };
  const context = vm.createContext({
    URL,
    clearTimeout,
    console,
    setTimeout,
    document: {
      addEventListener() {},
      getElementById(id) {
        if (!elements.has(id)) elements.set(id, makeElement());
        return elements.get(id);
      },
    },
    window: { addEventListener() {}, close() {} },
    chrome: {
      runtime: {
        connectNative() { return retryPort; },
      },
    },
  });
  vm.runInContext(popupSource, context);
  vm.runInContext(`
    nativePort = {
      postMessage() {},
      disconnect() {},
    };
    renderResult({ result: 'created', referenceID: 42, title: 'A paper' });
    openInRubien();
    handleNativeResponse({
      ok: false,
      error: { message: 'macOS could not open Rubien.' },
    });
  `, context);

  assert.equal(elements.get('result-title').textContent, 'Imported');
  assert.equal(elements.get('result-open-error').textContent, 'macOS could not open Rubien.');
  assert.equal(elements.get('result-open-error').classList.contains('hidden'), false);
  assert.equal(elements.get('open-button').disabled, false);
  assert.equal(elements.get('open-button').textContent, 'Open in Rubien');

  vm.runInContext('openInRubien()', context);
  assert.deepEqual(retryMessages, [{ version: 4, command: 'open', referenceID: 42 }]);

  disconnectListener();
  assert.equal(
    elements.get('result-open-error').textContent,
    'Rubien closed the connection before opening this item.'
  );
  assert.equal(elements.get('open-button').disabled, false);
});

test('confirmation downloads a publisher PDF with Chrome before importing', async () => {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, makeElement());
    return elements.get(id);
  };
  let downloadOptions;

  const context = vm.createContext({
    URL,
    clearTimeout,
    console,
    setTimeout,
    document: {
      addEventListener() {},
      getElementById: element,
    },
    window: {
      addEventListener() {},
      close() {},
    },
    chrome: {
      downloads: {
        async download(options) {
          downloadOptions = options;
          return 17;
        },
        async search({ id }) {
          return [{
            id,
            state: 'complete',
            filename: '/Users/test/Downloads/Rubien/rubien-123e4567-e89b-12d3-a456-426614174000.pdf',
          }];
        },
        onChanged: {
          addListener() {},
          removeListener() {},
        },
        async removeFile() {},
        async erase() {},
        async cancel() {},
      },
    },
  });

  vm.runInContext(popupSource, context);
  vm.runInContext(`
    nativePort = {
      postMessage(message) { globalThis.confirmMessage = message; },
      disconnect() {},
    };
    confirmationID = '123e4567-e89b-12d3-a456-426614174000';
    previewOffersPDF = true;
    previewPDFURL = 'https://www.science.org/doi/pdf/10.1126/scirobotics.adz7397?download=true';
    document.getElementById('download-pdf-checkbox').checked = true;
  `, context);

  await vm.runInContext('confirmImport()', context);

  assert.equal(
    downloadOptions.url,
    'https://www.science.org/doi/pdf/10.1126/scirobotics.adz7397?download=true'
  );
  assert.equal(
    downloadOptions.filename,
    'Rubien/rubien-123e4567-e89b-12d3-a456-426614174000.pdf'
  );
  assert.equal(downloadOptions.conflictAction, 'overwrite');
  assert.equal(downloadOptions.saveAs, false);
  assert.equal(
    context.confirmMessage.downloadedPDFPath,
    '/Users/test/Downloads/Rubien/rubien-123e4567-e89b-12d3-a456-426614174000.pdf'
  );
  assert.equal(context.confirmMessage.downloadPDF, true);
});

test('direct PDF is staged through Chrome with a token-bound filename', async () => {
  const elements = new Map();
  let downloadOptions;
  const context = vm.createContext({
    URL,
    clearTimeout,
    console,
    setTimeout,
    crypto: {
      randomUUID: () => '123e4567-e89b-12d3-a456-426614174001',
    },
    document: {
      addEventListener() {},
      getElementById(id) {
        if (!elements.has(id)) elements.set(id, makeElement());
        return elements.get(id);
      },
    },
    window: { addEventListener() {}, close() {} },
    chrome: {
      downloads: {
        async download(options) {
          downloadOptions = options;
          return 18;
        },
        async search({ id }) {
          return [{
            id,
            state: 'complete',
            filename: '/Users/test/Downloads/Rubien/rubien-preview-123e4567-e89b-12d3-a456-426614174001.pdf',
          }];
        },
        onChanged: { addListener() {}, removeListener() {} },
      },
    },
  });
  vm.runInContext(popupSource, context);

  const page = await vm.runInContext(
    `stageDirectFileWithChrome({ url: 'https://publisher.example/private.pdf' })`,
    context
  );

  assert.equal(downloadOptions.url, 'https://publisher.example/private.pdf');
  assert.equal(
    downloadOptions.filename,
    'Rubien/rubien-preview-123e4567-e89b-12d3-a456-426614174001.pdf'
  );
  assert.equal(
    page.browserDownloadedFilePath,
    '/Users/test/Downloads/Rubien/rubien-preview-123e4567-e89b-12d3-a456-426614174001.pdf'
  );
  assert.equal(page.browserDownloadToken, '123e4567-e89b-12d3-a456-426614174001');
});

test('download listener is registered before the initial status check', async () => {
  let listener = null;
  const context = vm.createContext({
    URL,
    clearTimeout,
    console,
    setTimeout,
    document: { addEventListener() {}, getElementById: () => makeElement() },
    window: { addEventListener() {}, close() {} },
    chrome: {
      downloads: {
        async search({ id }) {
          assert.equal(typeof listener, 'function');
          return [{ id, state: 'complete', filename: '/tmp/paper.pdf' }];
        },
        onChanged: {
          addListener(value) { listener = value; },
          removeListener() {},
        },
      },
    },
  });
  vm.runInContext(popupSource, context);

  const item = await vm.runInContext('waitForDownload(19)', context);
  assert.equal(item.filename, '/tmp/paper.pdf');
});

test('cleanup transfers confirmed file ownership to the native host', async () => {
  const calls = [];
  const context = vm.createContext({
    URL,
    clearTimeout,
    console,
    setTimeout,
    document: { addEventListener() {}, getElementById: () => makeElement() },
    window: { addEventListener() {}, close() {} },
    chrome: {
      runtime: {
        async sendMessage(message) { calls.push(['forget', message.downloadId]); },
      },
      downloads: {
        async cancel(id) { calls.push(['cancel', id]); },
        async removeFile(id) { calls.push(['remove', id]); },
        async erase({ id }) { calls.push(['erase', id]); },
      },
    },
  });
  vm.runInContext(popupSource, context);
  vm.runInContext('pendingDownloadID = 20; confirmationAwaitingHost = true;', context);

  await vm.runInContext('cleanupPDFDownload()', context);
  assert.deepEqual(calls, [['forget', 20]]);

  vm.runInContext('pendingDownloadID = 21; confirmationAwaitingHost = false;', context);
  await vm.runInContext('cleanupPDFDownload()', context);
  assert.deepEqual(calls, [
    ['forget', 20],
    ['cancel', 21],
    ['remove', 21],
    ['erase', 21],
  ]);
});
