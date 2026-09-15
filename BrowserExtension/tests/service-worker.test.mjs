import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const workerSource = await readFile(new URL('../service-worker.js', import.meta.url), 'utf8');

test('OpenReview PDF tabs read forum citation metadata in a background tab', async () => {
  const calls = [];
  const removed = [];
  const captured = {
    url: 'https://openreview.net/forum?id=vgZDcUetWS',
    title: 'A Paper',
    siteName: 'OpenReview',
    citation: { title: 'A Paper', authors: ['A. Author'] },
  };
  const context = vm.createContext({
    URL,
    setInterval,
    clearInterval,
    setTimeout,
    clearTimeout,
    console: { warn() {} },
    chrome: {
      runtime: { onMessage: { addListener() {} } },
      scripting: {
        async executeScript(options) {
          calls.push(options);
          return [{ result: captured }];
        },
      },
      tabs: {
        async create(options) {
          calls.push(options);
          return { id: 84, status: 'complete' };
        },
        async remove(tabId) {
          removed.push(tabId);
        },
        onUpdated: { addListener() {}, removeListener() {} },
      },
    },
  });
  vm.runInContext(workerSource, context);
  for (const url of [
    'https://openreview.net/pdf?id=vgZDcUetWS',
    'https://openreview.net/pdf?download=true&id=vgZDcUetWS#page=2',
  ]) {
    context.tab = { tabId: 42, url, title: 'openreview.net' };
    const page = await vm.runInContext('extractTab(tab)', context);
    assert.deepEqual(structuredClone(page), {
      ...captured,
      url,
      canonicalURL: null,
    });
  }
  assert.equal(calls.length, 4);
  assert.equal(calls[0].url, 'https://openreview.net/forum?id=vgZDcUetWS');
  assert.equal(calls[0].active, false);
  assert.equal(calls[1].target.tabId, 84);
  assert.equal(typeof calls[1].func, 'function');
  assert.deepEqual(structuredClone(calls[1].args), ['vgZDcUetWS']);
  assert.deepEqual(removed, [84, 84]);
});

test('OpenReview forum tabs capture rendered citation metadata before staging their PDF', async () => {
  const calls = [];
  const captured = {
    url: 'https://openreview.net/forum?id=ieUs1hK3HG',
    title: 'Does Reasoning Improve Seeing? Understanding When Vision-Language Models Benefit from Thinking',
    citation: {
      title: 'Does Reasoning Improve Seeing? Understanding When Vision-Language Models Benefit from Thinking',
      authors: ['Jing Bi', 'Luchuan Song'],
      publicationDate: '2026/05/01',
    },
  };
  const context = vm.createContext({
    URL,
    setInterval,
    clearInterval,
    setTimeout,
    clearTimeout,
    console: { warn() {} },
    chrome: {
      runtime: { onMessage: { addListener() {} } },
      scripting: {
        async executeScript(options) {
          calls.push(options);
          return options.files ? [] : [{ result: captured }];
        },
      },
    },
  });
  vm.runInContext(workerSource, context);
  context.tab = {
    tabId: 42,
    url: captured.url,
    title: 'Forum | OpenReview',
  };

  const page = await vm.runInContext('extractTab(tab)', context);
  assert.deepEqual(structuredClone(page), captured);
  assert.equal(calls.length, 1);
  assert.equal(typeof calls[0].func, 'function');
  assert.deepEqual(structuredClone(calls[0].args), ['ieUs1hK3HG']);
});

test('OpenReview background metadata tabs are removed when extraction fails', async () => {
  const removed = [];
  const context = vm.createContext({
    URL,
    setInterval,
    clearInterval,
    setTimeout,
    clearTimeout,
    console: { warn() {} },
    chrome: {
      runtime: { onMessage: { addListener() {} } },
      scripting: {
        async executeScript() {
          throw new Error('citation unavailable');
        },
      },
      tabs: {
        async create() { return { id: 84, status: 'complete' }; },
        async remove(tabId) { removed.push(tabId); },
        onUpdated: { addListener() {}, removeListener() {} },
      },
    },
  });
  vm.runInContext(workerSource, context);
  context.tab = {
    tabId: 42,
    url: 'https://openreview.net/pdf?id=ieUs1hK3HG',
    title: 'openreview.net',
  };

  const page = await vm.runInContext('extractTab(tab)', context);
  assert.deepEqual(structuredClone(page), {
    url: context.tab.url,
    title: 'openreview.net',
  });
  assert.deepEqual(removed, [84]);
});

test('OpenReview background load handles completion before its listener fires', async () => {
  let listener;
  let removedListener;
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    chrome: {
      runtime: { onMessage: { addListener() {} } },
      tabs: {
        async get(tabId) {
          assert.equal(tabId, 84);
          return { id: tabId, status: 'complete' };
        },
        onUpdated: {
          addListener(value) { listener = value; },
          removeListener(value) { removedListener = value; },
        },
      },
    },
  });
  vm.runInContext(workerSource, context);

  await vm.runInContext("waitForTabComplete(84, 'loading')", context);
  assert.equal(typeof listener, 'function');
  assert.equal(removedListener, listener);
});

test('OpenReview citation extraction accepts citation_online_date', async () => {
  const values = {
    citation_title: ['A Paper'],
    citation_author: ['A. Author', 'B. Author'],
    citation_online_date: ['2026/05/01'],
    citation_conference_title: ['ICML'],
    citation_pdf_url: ['/pdf?id=ieUs1hK3HG'],
  };
  const metas = Object.entries(values).flatMap(([name, contents]) =>
    contents.map((content) => ({
      getAttribute(attribute) {
        if (attribute === 'name') return name;
        if (attribute === 'property') return null;
        if (attribute === 'content') return content;
        return null;
      },
    })),
  );
  const context = vm.createContext({
    URL,
    chrome: { runtime: { onMessage: { addListener() {} } } },
    location: {
      href: 'https://openreview.net/forum?id=ieUs1hK3HG',
    },
    document: {
      URL: 'https://openreview.net/forum?id=ieUs1hK3HG',
      head: { querySelectorAll() { return metas; } },
    },
  });
  vm.runInContext(workerSource, context);

  const page = await vm.runInContext("extractOpenReviewCitation('ieUs1hK3HG')", context);
  assert.equal(page.citation.publicationDate, '2026/05/01');
  assert.deepEqual(structuredClone(page.citation.authors), ['A. Author', 'B. Author']);
  assert.equal(page.citation.pdfURL, 'https://openreview.net/pdf?id=ieUs1hK3HG');
});

test('OpenReview citation extraction observes metadata populated in place', async () => {
  const contents = { citation_title: '', citation_author: '' };
  const metas = Object.keys(contents).map((name) => ({
    getAttribute(attribute) {
      if (attribute === 'name') return name;
      if (attribute === 'property') return null;
      if (attribute === 'content') return contents[name];
      return null;
    },
  }));
  let mutationCallback;
  let observedOptions;
  let disconnected = false;
  class MutationObserver {
    constructor(callback) { mutationCallback = callback; }
    observe(_target, options) { observedOptions = options; }
    disconnect() { disconnected = true; }
  }
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    MutationObserver,
    chrome: { runtime: { onMessage: { addListener() {} } } },
    location: { href: 'https://openreview.net/forum?id=ieUs1hK3HG' },
    document: {
      URL: 'https://openreview.net/forum?id=ieUs1hK3HG',
      documentElement: {},
      head: { querySelectorAll() { return metas; } },
    },
  });
  vm.runInContext(workerSource, context);

  const extraction = vm.runInContext("extractOpenReviewCitation('ieUs1hK3HG')", context);
  assert.deepEqual(structuredClone(observedOptions), {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['content'],
  });
  contents.citation_title = 'Late Paper';
  contents.citation_author = 'Late Author';
  mutationCallback();

  const page = await extraction;
  assert.equal(page.citation.title, 'Late Paper');
  assert.deepEqual(structuredClone(page.citation.authors), ['Late Author']);
  assert.equal(disconnected, true);
});

test('non-PDF OpenReview paths continue through normal page extraction', async () => {
  let injections = 0;
  const context = vm.createContext({
    URL,
    setInterval,
    clearInterval,
    console: { warn() {} },
    chrome: {
      runtime: { onMessage: { addListener() {} } },
      scripting: {
        async executeScript() {
          injections += 1;
          throw new Error('No page extraction in this test');
        },
      },
    },
  });
  vm.runInContext(workerSource, context);
  for (const url of [
    'https://openreview.net/forum?id=',
    'https://openreview.net/challenge?id=ieUs1hK3HG',
    'https://openreview.net.example/pdf?id=vgZDcUetWS',
  ]) {
    context.tab = { tabId: 42, url };
    await vm.runInContext('extractTab(tab)', context);
  }
  assert.equal(injections, 3);
});
