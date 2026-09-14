import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {test} from 'node:test';
import {pathToFileURL} from 'node:url';
import {NATIVE_LOCK_DIRECTORY_VARIABLE, patchNativeLockRuntimeDirectory} from '../runtime-directory.mjs';

// The pinned upstream shape, verbatim, so this suite runs on a clean clone.
// The staged copy under ios/build/ is checked by tests/package/stage.test.mjs.
const resolver = 'function resolveStateLifecycleRuntimeDirectory() {\n\treturn process.platform === "win32" ? path.join(os.homedir(), "AppData", "Local", "OpenClaw", "locks") : "/tmp";\n}';
const source = [
  'import path from "node:path";',
  'import os from "node:os";',
  resolver,
  'function acquireLifecycleCoordinator(family, params) {',
  '\tconst coordinatorPath = params.coordinatorPath ?? resolveLifecycleCoordinatorPath(family, {',
  '\t\truntimeDirectory: params.runtimeDirectory ?? resolveStateLifecycleRuntimeDirectory(),',
  '\t});',
  '\treturn coordinatorPath;',
  '}',
  'export { resolveStateLifecycleRuntimeDirectory as a, acquireLifecycleCoordinator as n };',
  '',
].join('\n');

async function load(t, code) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'operator-lock-directory-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const file = path.join(root, 'coordinator.mjs');
  fs.writeFileSync(file, code);
  return import(pathToFileURL(file).href);
}

test('the host-named directory wins and upstream /tmp remains the default', async t => {
  const patched = patchNativeLockRuntimeDirectory(source);
  const module = await load(t, patched);
  const previous = process.env[NATIVE_LOCK_DIRECTORY_VARIABLE];
  t.after(() => {
    if (previous === undefined) delete process.env[NATIVE_LOCK_DIRECTORY_VARIABLE];
    else process.env[NATIVE_LOCK_DIRECTORY_VARIABLE] = previous;
  });
  delete process.env[NATIVE_LOCK_DIRECTORY_VARIABLE];
  assert.equal(module.a(), process.platform === 'win32' ? path.join(os.homedir(), 'AppData', 'Local', 'OpenClaw', 'locks') : '/tmp');
  process.env[NATIVE_LOCK_DIRECTORY_VARIABLE] = '/container/Application Support/Operator/openclaw/locks';
  assert.equal(module.a(), '/container/Application Support/Operator/openclaw/locks');
  process.env[NATIVE_LOCK_DIRECTORY_VARIABLE] = '';
  assert.equal(module.a(), process.platform === 'win32' ? path.join(os.homedir(), 'AppData', 'Local', 'OpenClaw', 'locks') : '/tmp');
});

test('changes only the resolver', () => {
  const patched = patchNativeLockRuntimeDirectory(source);
  assert.equal(patched.replace(/function resolveStateLifecycleRuntimeDirectory\(\) \{[\s\S]*?\n\}/, resolver), source);
});

test('repeated packaging makes no further change', () => {
  const patched = patchNativeLockRuntimeDirectory(source);
  assert.equal(patchNativeLockRuntimeDirectory(patched), patched);
});

test('refuses a changed resolver or a coordinator that bypasses it', () => {
  for (const changed of [
    source.replace(resolver, resolver.replace('"/tmp"', 'os.tmpdir()')),
    source.replace(resolver, ''),
    source + resolver,
    source.replace('params.runtimeDirectory ?? resolveStateLifecycleRuntimeDirectory()', '"/tmp"'),
    source.replace('export { resolveStateLifecycleRuntimeDirectory as a,', 'export {'),
  ]) assert.throws(() => patchNativeLockRuntimeDirectory(changed), /Pinned OpenClaw source changed/);
});
