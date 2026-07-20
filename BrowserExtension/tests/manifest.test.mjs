import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const extensionRoot = new URL('../', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('manifest.json', extensionRoot), 'utf8'));

function pngMetadata(data) {
  assert.equal(data.subarray(1, 4).toString('ascii'), 'PNG');
  return {
    width: data.readUInt32BE(16),
    height: data.readUInt32BE(20),
    colorType: data[25],
  };
}

test('manifest uses transparent Rubien icons at Chrome sizes', async () => {
  const sizes = [16, 32, 48, 128];

  for (const size of sizes) {
    const relativePath = `icons/icon-${size}.png`;
    assert.equal(manifest.icons[String(size)], relativePath);
    const metadata = pngMetadata(await readFile(new URL(relativePath, extensionRoot)));
    assert.deepEqual(metadata, { width: size, height: size, colorType: 6 });
  }

  assert.equal(manifest.action.default_icon['16'], 'icons/icon-16.png');
  assert.equal(manifest.action.default_icon['32'], 'icons/icon-32.png');
});

test('manifest maps the macOS shortcut to Command', () => {
  assert.equal(
    manifest.commands._execute_action.suggested_key.mac,
    'Command+Shift+R'
  );
});
