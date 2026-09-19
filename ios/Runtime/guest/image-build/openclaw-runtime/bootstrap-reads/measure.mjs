// Account-free fixture benchmark. Run with the packaged OpenClaw dist directory.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { pathToFileURL } from 'node:url';
import { parallelizeBootstrapReads } from './transform.mjs';

assert(process.argv[2], 'Pass the public packaged OpenClaw dist directory');
const dist = path.resolve(process.argv[2]);
const source = await fsp.readFile(path.join(dist, 'workspace-BFk42BX6.js'), 'utf8');
function section(first, next) {
 const start = source.indexOf(first);
 const end = source.indexOf(next, start);
 assert(start >= 0 && end > start, `Pinned source section missing: ${first}`);
 return source.slice(start, end);
}
const guards = section('const TRANSIENT_WORKSPACE_READ_CODES', 'function stripFrontMatter');
const transient = section('function isTransientWorkspaceReadError', 'async function fileContentDiffersFromTemplate');
const loader = section('async function loadWorkspaceBootstrapFiles', 'const SUBAGENT_BOOTSTRAP_ALLOWLIST');
const { o: openRootFileFollowingParents, r: isRootFileMissingFailure } = await import(pathToFileURL(path.join(dist, 'boundary-file-read-uaJcf6X6.js')));
const { n: readWorkspaceBootstrapFile } = await import(pathToFileURL(path.join(dist, 'workspace-bootstrap-read-CUL2d6SJ.js')));
const { r: exactWorkspaceEntryExists } = await import(pathToFileURL(path.join(dist, 'root-memory-files-IL5Gznz4.js')));
const { t: retryAsync } = await import(pathToFileURL(path.join(dist, 'retry-DIUON3ys.js')));
const { r: truncateUtf16Safe } = await import(pathToFileURL(path.join(dist, 'utf16-slice-D_ngcYKd.js')));
const names = ['AGENTS.md', 'SOUL.md', 'IDENTITY.md', 'USER.md', 'BOOTSTRAP.md', 'MEMORY.md'];
function makeLoader(code) {
 let boundedReads = 0;
 const context = vm.createContext({
  fs, path, Error, RangeError, retryAsync, openRootFileFollowingParents,
  isRootFileMissingFailure, exactWorkspaceEntryExists, truncateUtf16Safe,
  readWorkspaceBootstrapFile: async fd => { boundedReads++; return readWorkspaceBootstrapFile(fd); },
  resolveUserPath: value => value,
  createSubsystemLogger: () => ({ warn() {} }),
  DEFAULT_AGENTS_FILENAME: names[0], DEFAULT_SOUL_FILENAME: names[1],
  DEFAULT_IDENTITY_FILENAME: names[2], DEFAULT_USER_FILENAME: names[3],
  DEFAULT_BOOTSTRAP_FILENAME: names[4], DEFAULT_MEMORY_FILENAME: names[5]
 });
 vm.runInContext(guards + transient + code + '\nglobalThis.load = loadWorkspaceBootstrapFiles;', context);
 return { load: context.load, readCount: () => boundedReads };
}
const variants = { baseline: makeLoader(loader), candidate: makeLoader(parallelizeBootstrapReads(loader)) };
const scratch = await fsp.mkdtemp(path.join(os.tmpdir(), 'operator-bootstrap-measure-'));
const workspace = path.join(scratch, 'workspace');
const plain = value => JSON.parse(JSON.stringify(value));
try {
 await fsp.mkdir(workspace);
 for (const name of names) await fsp.writeFile(path.join(workspace, name), `Synthetic ${name}\n`);
 assert.deepEqual(plain(await variants.baseline.load(workspace)), plain(await variants.candidate.load(workspace)));
 const timings = { baseline: [], candidate: [] };
 for (let trial = 0; trial < 5; trial++) {
  const order = trial % 2 ? ['candidate', 'baseline'] : ['baseline', 'candidate'];
  for (const name of order) {
   const before = performance.now();
   for (let run = 0; run < 20; run++) await variants[name].load(workspace);
   timings[name].push((performance.now() - before) / 20);
  }
 }
 for (const variant of Object.values(variants)) assert.equal(variant.readCount(), 6, 'Unchanged content must use the existing identity-checked cache');
 await fsp.writeFile(path.join(workspace, 'AGENTS.md'), 'Changed synthetic fixture with a different length');
 await fsp.unlink(path.join(workspace, 'SOUL.md'));
 await fsp.unlink(path.join(workspace, 'MEMORY.md'));
 await fsp.writeFile(path.join(scratch, 'outside.md'), 'outside fixture must stay outside');
 await fsp.unlink(path.join(workspace, 'USER.md'));
 await fsp.symlink(path.join(scratch, 'outside.md'), path.join(workspace, 'USER.md'));
 const baseline = plain(await variants.baseline.load(workspace));
 const candidate = plain(await variants.candidate.load(workspace));
 assert.deepEqual(candidate, baseline);
 assert.match(candidate[0].content, /^Changed synthetic/);
 assert.equal(candidate[1].missing, true);
 assert.match(candidate.find(file => file.name === 'USER.md').content, /^\[UNREADABLE:/);
 assert(!candidate.some(file => file.name === 'MEMORY.md'));
 assert(!JSON.stringify(candidate).includes('outside fixture must stay outside'));
 for (const variant of Object.values(variants)) assert.equal(variant.readCount(), 7, 'Only the changed valid file should need new content');
 for (const [variant, values] of Object.entries(timings)) {
  values.sort((a, b) => a - b);
  console.log(JSON.stringify({ operation: 'guarded-bootstrap-fixture', platform: process.platform, arch: process.arch, node: process.version, variant, trials: 5, loadsPerTrial: 20, medianMs: values[2] }));
 }
 console.log('OPERATOR_BOOTSTRAP_FIXTURE_PASS');
} finally {
 await fsp.rm(scratch, { recursive: true, force: true });
}
