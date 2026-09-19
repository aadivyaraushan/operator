import assert from 'node:assert/strict';
import test from 'node:test';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { crc32 } from 'node:zlib';

test('cache matching recognizes a real Node-generated source header', async () => {
  const directory = await fs.mkdtemp(join(tmpdir(), 'operator-cache-header-test-'));
  try {
    const sourcePath = join(directory, 'fixture.cjs');
    const cacheRoot = join(directory, 'cache');
    await fs.writeFile(sourcePath, 'module.exports = 1234567;\n');
    const environment = { ...process.env, NODE_COMPILE_CACHE: cacheRoot };
    delete environment.NODE_DISABLE_COMPILE_CACHE;
    execFileSync(process.execPath, ['-e', `require(${JSON.stringify(sourcePath)})`], { env: environment });
    const listRegularFiles = async root => {
      const paths = [];
      for (const entry of await fs.readdir(root, { withFileTypes: true })) {
        const path = join(root, entry.name);
        if (entry.isDirectory()) paths.push(...await listRegularFiles(path));
        else if (entry.isFile()) paths.push(path);
      }
      return paths;
    };
    const code = await fs.readFile(new URL('./guest.mjs', import.meta.url), 'utf8');
    const start = code.indexOf('async function matchingCacheHeaderCount(');
    const end = code.indexOf('\nasync function hasMatchingCacheHeader(', start);
    assert.ok(start >= 0 && end > start);
    const count = new Function('readFile', 'crc32', 'listRegularFiles', 'open',
      `${code.slice(start, end)};return matchingCacheHeaderCount;`)(fs.readFile, crc32, listRegularFiles, fs.open);
    assert.equal(await count(cacheRoot, sourcePath), 1);
    await fs.writeFile(sourcePath, 'module.exports = 7654321;\n');
    assert.equal(await count(cacheRoot, sourcePath), 0, 'changed source must not match');
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});
