import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const workerSource = await readFile(new URL('../service-worker.js', import.meta.url), 'utf8');

test('OpenReview forum and PDF tabs skip DOM extraction and preserve the selected URL', async () => {
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
    'https://openreview.net/forum?id=ieUs1hK3HG',
    'https://openreview.net/forum?noteId=another-note&id=ieUs1hK3HG#discussion',
  ]) {
    context.tab = { tabId: 42, url, title: 'openreview.net' };
    const page = await vm.runInContext('extractTab(tab)', context);
    assert.deepEqual(structuredClone(page), { url, title: 'openreview.net' });
  }
  assert.equal(injections, 0);

  for (const url of [
    'https://openreview.net/forum?id=',
    'https://openreview.net/pdf?id=',
    'https://openreview.net.example/pdf?id=vgZDcUetWS',
  ]) {
    context.tab = { tabId: 42, url };
    await vm.runInContext('extractTab(tab)', context);
  }
  assert.equal(injections, 3);
});
