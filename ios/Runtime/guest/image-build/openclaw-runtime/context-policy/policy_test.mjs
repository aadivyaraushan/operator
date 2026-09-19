// Characterize the pinned continuation policy before changing app configuration.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';

const dist = 'ios/build/runtime-recovery/openclaw-source/package/dist/';
const builtin = await readFile(dist + 'builtin-openclaw-zQV8Wwjr.js', 'utf8');
const bootstrap = await readFile(dist + 'bootstrap-files-CHsP1LeZ.js', 'utf8');
function extract(source, startText, endText) {
 const start = source.indexOf(startText);
 const end = source.indexOf(endText, start);
 assert(start >= 0 && end > start);
 return source.slice(start, end);
}
const policy = extract(builtin, 'async function resolveAttemptBootstrapContext(', '/**\n* Builds the compact prompt-cache metadata');
const completed = extract(bootstrap, 'async function hasCompletedBootstrapTurn(', '/** Builds a session-scoped warning sink');
const marker = { type: 'custom', customType: 'openclaw:bootstrap-context:full' };
function fixture(records) {
 const context = vm.createContext({
  CONTINUATION_SCAN_MAX_RECORDS: 500,
  readRecentSessionTranscriptActiveEvents: () => records,
  isHeartbeatLifecycleRunKind: kind => kind === 'heartbeat'
 });
 vm.runInContext(completed + policy + '\nglobalThis.policy = resolveAttemptBootstrapContext; globalThis.completed = hasCompletedBootstrapTurn;', context);
 let reads = 0;
 const params = {
  contextInjectionMode: 'continuation-skip', bootstrapMode: 'none',
  bootstrapContextRunKind: 'default', bootstrapContextMode: 'full',
  hasCompletedBootstrapTurn: () => context.completed({ agentId: 'fixture', sessionId: 'fixture', sessionKey: 'fixture', storePath: '/synthetic-only' }),
  resolveBootstrapContextForRun: async () => { reads++; return { bootstrapFiles: [{ content: 'fresh instruction' }], contextFiles: [{ content: 'fresh instruction' }] }; }
 };
 return { run: overrides => context.policy({ ...params, ...overrides }), reads: () => reads };
}
test('continuation-skip does not inspect edited instruction files after its completion marker', async () => {
 const f = fixture([marker]);
 const result = await f.run();
 assert.equal(f.reads(), 0);
 assert.equal(result.contextFiles.length, 0);
 assert.equal(result.isContinuationTurn, true);
});
for (const type of ['compaction', 'reset']) test(`${type} after the marker requests fresh context`, async () => {
 const f = fixture([marker, { type }]);
 const result = await f.run();
 assert.equal(f.reads(), 1);
 assert.equal(result.contextFiles[0].content, 'fresh instruction');
});
test('always mode preserves fresh instruction loading', async () => {
 const f = fixture([marker]);
 await f.run({ contextInjectionMode: 'always' });
 await f.run({ contextInjectionMode: 'always' });
 assert.equal(f.reads(), 2);
});
test('heartbeat and full bootstrap do not skip context', async () => {
 const f = fixture([marker]);
 await f.run({ bootstrapContextRunKind: 'heartbeat' });
 await f.run({ bootstrapMode: 'full' });
 assert.equal(f.reads(), 2);
});
