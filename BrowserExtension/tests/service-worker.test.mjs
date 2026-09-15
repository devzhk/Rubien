import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const workerSource = await readFile(new URL('../service-worker.js', import.meta.url), 'utf8');

test('OpenReview PDF tabs skip DOM extraction and preserve the selected URL', async () => {
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
          throw new Error('PDF viewer rejects injection');
        },
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
    assert.deepEqual(structuredClone(page), { url, title: 'openreview.net' });
  }
  assert.equal(injections, 0);

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
  assert.equal(calls.length, 2);
  assert.deepEqual(structuredClone(calls[0].files), ['dist/ClipperDefuddle.js']);
  assert.equal(typeof calls[1].func, 'function');
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
