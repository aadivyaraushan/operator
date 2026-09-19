import assert from 'node:assert/strict';
import test from 'node:test';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('benchmark replacement preserves the existing inode and permissions', async () => {
  const directory = await fs.mkdtemp(join(tmpdir(), 'operator-cache-install-'));
  try {
    const source = join(directory, 'candidate.js');
    const target = join(directory, 'installed.js');
    await fs.writeFile(source, 'candidate', { mode: 0o600 });
    await fs.writeFile(target, 'original source is longer', { mode: 0o644 });
    const before = await fs.stat(target);
    const code = await fs.readFile(new URL('./guest.mjs', import.meta.url), 'utf8');
    const start = code.indexOf('async function installPatchedModule(');
    const end = code.indexOf('\nasync function main()', start);
    assert.ok(start >= 0 && end > start);
    const install = new Function('requireRegularFile', 'installedModule', 'copyFile', 'open', 'readFile', 'fail',
      `${code.slice(start, end)};return installPatchedModule;`)(
      fs.lstat, target, fs.copyFile, fs.open, fs.readFile, message => { throw new Error(message); });
    await install(source);
    const after = await fs.stat(target);
    assert.equal(after.ino, before.ino);
    assert.equal(after.mode, before.mode);
    assert.equal(after.uid, before.uid);
    assert.equal(after.gid, before.gid);
    assert.equal(await fs.readFile(target, 'utf8'), 'candidate');
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});
