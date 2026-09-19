import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import os from 'node:os';
import { closeSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { parallelizeBootstrapReads } from './transform.mjs';

const source = await fs.readFile('ios/build/runtime-recovery/openclaw-source/package/dist/workspace-BFk42BX6.js', 'utf8');
const start = source.indexOf('async function loadWorkspaceBootstrapFiles(dir) {');
const end = source.indexOf('\nconst SUBAGENT_BOOTSTRAP_ALLOWLIST', start);
assert(start >= 0 && end > start);
const loaderSource = parallelizeBootstrapReads(source.slice(start, end));
const names = ['AGENTS.md', 'SOUL.md', 'IDENTITY.md', 'USER.md', 'BOOTSTRAP.md', 'MEMORY.md'];
function harness(read, options = {}) {
 const context = vm.createContext({
  path, resolveUserPath: value => value,
  DEFAULT_AGENTS_FILENAME: names[0], DEFAULT_SOUL_FILENAME: names[1],
  DEFAULT_IDENTITY_FILENAME: names[2], DEFAULT_USER_FILENAME: names[3],
  DEFAULT_BOOTSTRAP_FILENAME: names[4], DEFAULT_MEMORY_FILENAME: names[5],
  exactWorkspaceEntryExists: options.exists ?? (async () => true),
  readWorkspaceFileWithGuards: read,
  setWorkspaceFileSourceIdentity: (file, identity) => { file.identity = identity; },
  isRootFileMissingFailure: options.isMissing ?? (result => result.reason === 'missing'),
  truncateUtf16Safe: value => value,
  workspaceLogger: { warn() {} }
 });
 vm.runInContext((options.source ?? loaderSource) + '\nglobalThis.load = loadWorkspaceBootstrapFiles;', context);
 return context.load;
}
test('starts all six independent guarded reads before waiting for completion', async () => {
 const started = [];
 const release = [];
 const load = harness(params => {
  started.push(path.basename(params.filePath));
  return new Promise(resolve => release.push(() => resolve({ ok: true, content: params.filePath, sourceIdentity: params.filePath })));
 });
 const pending = load('/synthetic-workspace');
 await new Promise(resolve => setImmediate(resolve));
 const count = started.length;
 for (const complete of release.toReversed()) complete();
 assert.equal(count, 6, 'guarded reads still wait for each preceding file');
 const files = await pending;
 assert.deepEqual(Array.from(files, file => file.name), names);
 assert(files.every(file => file.identity === file.path));
});
test('fresh reads preserve missing and rejected-file behavior', async () => {
 let calls = 0;
 const load = harness(async params => {
  calls++;
  const name = path.basename(params.filePath);
  if (name === 'SOUL.md') return { ok: false, reason: 'missing' };
  if (name === 'USER.md') return { ok: false, reason: 'validation' };
  return { ok: true, content: String(calls), sourceIdentity: params.filePath };
 });
 const first = await load('/synthetic-workspace');
 await load('/synthetic-workspace');
 assert.equal(calls, 12, 'every turn must keep fresh guarded reads');
 assert.equal(first[1].missing, true);
 assert.match(first[3].content, /^\[UNREADABLE:/);
 assert.deepEqual(Array.from(first, file => file.name), names);
});
test('refuses unexpected source instead of applying a partial rewrite', () => {
 assert.throws(() => parallelizeBootstrapReads('unrelated source'), /Expected one pinned/);
 assert.throws(() => parallelizeBootstrapReads(loaderSource), /Expected one pinned/);
});

test('real guarded files preserve edits, missing files and rejection of outside symlinks', async t => {
 const dist = path.resolve('ios/build/runtime-recovery/arm-production-runtime.ffhtxG/verified/usr/local/lib/node_modules/openclaw/dist');
 const { o: openGuarded, r: isMissing } = await import(pathToFileURL(path.join(dist, 'boundary-file-read-uaJcf6X6.js')));
 const { n: readBounded } = await import(pathToFileURL(path.join(dist, 'workspace-bootstrap-read-CUL2d6SJ.js')));
 const { r: exists } = await import(pathToFileURL(path.join(dist, 'root-memory-files-IL5Gznz4.js')));
 const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'operator-bootstrap-real-'));
 const workspace = path.join(scratch, 'workspace');
 await fs.mkdir(workspace);
 const read = async params => {
  const opened = await openGuarded({ absolutePath: params.filePath, rootPath: params.workspaceDir, boundaryLabel: 'workspace root' });
  if (!opened.ok) return opened;
  try { return { ok: true, content: await readBounded(opened.fd), sourceIdentity: opened.path }; }
  finally { closeSync(opened.fd); }
 };
 const baseline = harness(read, { source: source.slice(start, end), exists, isMissing });
 const candidate = harness(read, { exists, isMissing });
 const plain = value => JSON.parse(JSON.stringify(value));
 try {
  for (const name of names) await fs.writeFile(path.join(workspace, name), `test ${name}`);
  assert.deepEqual(plain(await candidate(workspace)), plain(await baseline(workspace)));
  const timings = { baseline: [], candidate: [] };
  for (let trial = 0; trial < 5; trial++) {
   const order = trial % 2 ? [['candidate', candidate], ['baseline', baseline]] : [['baseline', baseline], ['candidate', candidate]];
   for (const [name, load] of order) {
    const before = performance.now();
    for (let run = 0; run < 20; run++) await load(workspace);
    timings[name].push((performance.now() - before) / 20);
   }
  }
  for (const [name, values] of Object.entries(timings)) {
   values.sort((a,b) => a-b);
   t.diagnostic(JSON.stringify({ host: 'Mac', operation: 'six guarded fixture reads', variant: name, trials: 5, readsPerTrial: 20, medianMs: values[2] }));
  }
  await fs.writeFile(path.join(workspace, 'AGENTS.md'), 'updated fixture');
  await fs.unlink(path.join(workspace, 'SOUL.md'));
  await fs.unlink(path.join(workspace, 'MEMORY.md'));
  await fs.writeFile(path.join(scratch, 'outside.md'), 'outside fixture must not enter context');
  await fs.unlink(path.join(workspace, 'USER.md'));
  await fs.symlink(path.join(scratch, 'outside.md'), path.join(workspace, 'USER.md'));
  const result = plain(await candidate(workspace));
  assert.deepEqual(result, plain(await baseline(workspace)));
  assert.equal(result.find(file => file.name === 'AGENTS.md').content, 'updated fixture');
  assert.equal(result.find(file => file.name === 'SOUL.md').missing, true);
  assert.equal(result.some(file => file.name === 'MEMORY.md'), false);
  assert.match(result.find(file => file.name === 'USER.md').content, /^\[UNREADABLE:/);
  assert(!JSON.stringify(result).includes('outside fixture must not enter context'));
 } finally { await fs.rm(scratch, { recursive: true, force: true }); }
});
