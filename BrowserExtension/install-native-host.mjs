import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { access, mkdir, readFile, realpath, rename, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(here, '..');
const helperCandidate = resolve(projectRoot, '.build/debug/rubien-browser-host');
const extensionManifest = JSON.parse(
  await readFile(resolve(here, 'manifest.json'), 'utf8'),
);

await access(helperCandidate, constants.X_OK).catch(() => {
  throw new Error(
    `Missing ${helperCandidate}. Run "swift build --product rubien-browser-host" first.`,
  );
});

const helperPath = await realpath(helperCandidate);
const publicKey = Buffer.from(extensionManifest.key, 'base64');
const extensionID = createHash('sha256')
  .update(publicKey)
  .digest('hex')
  .slice(0, 32)
  .replace(/[0-9a-f]/g, (digit) =>
    String.fromCharCode('a'.charCodeAt(0) + Number.parseInt(digit, 16)),
  );
const expectedExtensionID = 'pggebflfobimhklmgebcfgeobajkgdbb';

if (extensionID !== expectedExtensionID) {
  throw new Error(
    `Extension key produced ${extensionID}; expected ${expectedExtensionID}.`,
  );
}

const hostName = 'com.rubien.browser_clipper';
const hostDirectory = join(
  homedir(),
  'Library',
  'Application Support',
  'Google',
  'Chrome',
  'NativeMessagingHosts',
);
const hostManifestPath = join(hostDirectory, `${hostName}.json`);
const hostManifest = {
  name: hostName,
  description: 'Import the active Chrome tab into Rubien',
  path: helperPath,
  type: 'stdio',
  allowed_origins: [`chrome-extension://${extensionID}/`],
};

if (!process.argv.includes('--dry-run')) {
  const temporaryPath = `${hostManifestPath}.tmp-${process.pid}`;
  await mkdir(hostDirectory, { recursive: true });
  await writeFile(temporaryPath, `${JSON.stringify(hostManifest, null, 2)}\n`, {
    mode: 0o600,
  });
  await rename(temporaryPath, hostManifestPath);
}

console.log(`Extension ID: ${extensionID}`);
console.log(`Helper: ${helperPath}`);
console.log(`Native host manifest: ${hostManifestPath}`);
if (process.argv.includes('--dry-run')) {
  console.log('Dry run: no files written.');
}
