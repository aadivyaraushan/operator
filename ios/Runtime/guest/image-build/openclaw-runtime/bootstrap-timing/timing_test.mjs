import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import vm from 'node:vm';
import { test } from 'node:test';

const source = readFileSync(process.env.OPERATOR_BOOTSTRAP_SOURCE || 'ios/build/runtime-recovery/arm-production-runtime.ffhtxG/verified/usr/local/lib/node_modules/openclaw/dist/builtin-openclaw-zQV8Wwjr.js', 'utf8');
const baseline = process.argv.includes('--baseline');
const transform = baseline ? s => s : (await import('./transform.mjs')).transform;
function extract(s) {
  const start = s.indexOf('async function prepareEmbeddedAttemptBootstrap(params) {');
  return s.slice(start, s.indexOf('\n//#endregion', start));
}
async function run(s, scenario) {
  const calls = [], marks = [];
  const files = [{ name: 'AGENTS.md', path: '/work/AGENTS.md', missing: false }];
  const failure = scenario.failure;
  const deps = {
    path, DEFAULT_AGENTS_FILENAME: 'AGENTS.md', DEFAULT_BOOTSTRAP_FILENAME: 'BOOTSTRAP.md',
    resolveContextInjectionMode: () => scenario.mode || 'always', makeBootstrapWarn: () => () => {}, log$5: { warn() {} },
    resolveBootstrapFilesForRun: async p => { calls.push(['files', p.workspaceDir]); if (failure === 'files') throw scenario.error; return files; },
    hasCompletedBootstrapTurn: async () => { calls.push(['completed']); return true; },
    isWorkspaceBootstrapPending() {}, isPrimaryBootstrapRun: () => true, isHeartbeatLifecycleRunKind: () => false,
    resolveWorkspaceBootstrapRouting: async p => { calls.push(['routing', Boolean(p.bootstrapFiles)]); if (failure === 'routing') throw scenario.error; return { bootstrapMode: scenario.full ? 'full' : 'normal', includeBootstrapInSystemContext: true }; },
    resolveAttemptBootstrapContext: async p => {
      calls.push(['context', p.contextInjectionMode]);
      if (p.contextInjectionMode === 'never' || (p.contextInjectionMode === 'continuation-skip' && !scenario.full)) return { bootstrapFiles: [], contextFiles: [], shouldRecordCompletedBootstrapTurn: false };
      const result = await p.resolveBootstrapContextForRun();
      return { ...result, shouldRecordCompletedBootstrapTurn: true };
    },
    buildBootstrapContextForFiles: f => f.map(x => ({ path: x.path, content: 'synthetic' })),
    remapInjectedContextFilesToWorkspace: p => p.files,
    buildBootstrapInjectionStats: () => [], buildBootstrapBudgetState: () => ({ budget: 7 }), isEmbeddedMode: () => false,
  };
  const fn = vm.runInNewContext(`(${extract(s)})`, deps);
  let result, error;
  try {
    result = await fn({ attempt: { config: {}, sessionKey: 'synthetic', operation: scenario.settled ? 'settled-tool-finalization' : 'normal' }, resolvedWorkspace: '/work', effectiveWorkspace: '/work', bootstrapWorkspaceDir: scenario.layered ? '/bootstrap' : undefined, isRawModelRun: scenario.raw, markStage: stage => marks.push(stage) });
  } catch (e) { error = e; }
  return { result: JSON.parse(JSON.stringify(result ?? null)), error, calls, marks };
}
for (const scenario of [{}, { mode: 'continuation-skip' }, { mode: 'continuation-skip', full: true }, { mode: 'never' }, { raw: true }, { settled: true }, { layered: true }, { failure: 'files' }, { failure: 'routing' }]) {
  test(`same behavior and ordered timing ${JSON.stringify(scenario)}`, async () => {
    scenario.error = new Error('synthetic rejection');
    const old = await run(source, scenario), next = await run(transform(source), scenario);
    assert.deepEqual(next.result, old.result);
    assert.deepEqual(next.calls, old.calls);
    assert.equal(next.error, old.error);
    const stages = next.marks.filter(x => x !== 'bootstrap-context');
    const expected = old.calls.flatMap(([kind]) => ['files', 'routing'].includes(kind) ? [`bootstrap-${kind}-start`, ...(scenario.failure === kind ? [] : [`bootstrap-${kind}-end`])] : []);
    assert.deepEqual(stages, expected);
  });
}
if (!baseline) test('exact pinned transform rejects drift and accepts exact repeated application', () => {
  const changed = transform(source);
  assert.equal(changed.replace(extract(changed), extract(source)), source);
  assert.equal(transform(changed), changed);
  assert.throws(() => transform(source.replace('const { attempt } = params;', 'const { attempt } = { ...params };')), /unsupported/i);
  assert.throws(() => transform(changed.replace('bootstrap-files-start', 'bootstrap-files-drift')), /unsupported/i);
});
if (!baseline) test('CLI writes new output only and refuses existing source or output', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'operator-bootstrap-timing-'));
  try {
    const input = path.join(directory, 'input.js'), output = path.join(directory, 'output.js');
    writeFileSync(input, source);
    const cli = new URL('./apply.mjs', import.meta.url);
    const runCLI = target => spawnSync(process.execPath, [fileURLToPath(cli), input, target], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', TMPDIR: '/private/tmp' } });
    assert.equal(runCLI(output).status, 0);
    assert.equal(readFileSync(output, 'utf8'), transform(source));
    assert.notEqual(runCLI(output).status, 0);
    assert.notEqual(runCLI(input).status, 0);
    assert.equal(readFileSync(input, 'utf8'), source);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
