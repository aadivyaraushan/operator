import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync, writeFileSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import vm from 'node:vm';

const source = readFileSync(process.env.OPERATOR_PROVIDER_SOURCE || 'ios/build/runtime-recovery/openclaw-source/package/dist/attempt.model-diagnostic-events-B4dGIs0S.js', 'utf8');
const baseline = process.argv.includes('--baseline');
const transform = baseline ? s => s : (await import('./transform.mjs')).transform;
const names = ['createModelLifecycle', 'emitModelCallEnded', 'observeResponseChunk', 'observeResultMessageContent'];
function extract(s, name) {
  const start = s.indexOf(`function ${name}(`);
  const end = s.indexOf('\n}', start) + 2;
  return s.slice(start, end);
}
function harness(s, loggerThrows = false) {
  const logs = [], effects = [];
  let now = 1000;
  const secret = 'synthetic-secret-prompt-key-reply-runid';
  const deps = {
    Date: { now: () => now }, Number, WeakMap,
    createSubsystemLogger: () => ({ info: line => { if (loggerThrows) throw new Error(secret); logs.push(line); } }),
    freezeDiagnosticTraceContext: x => x, createChildDiagnosticTraceContext: x => x,
    areDiagnosticsEnabledForProcess: () => false,
    baseModelCallEvent: () => ({ runId: secret, callId: secret, provider: secret }),
    emitCoreModelRequestStartedDiagnosticEvent: () => effects.push('start'),
    modelContentPrivateData: x => x, dispatchModelCallStartedHook: () => {},
    withDiagnosticRequestContext: x => x,
    modelCallErrorFields: () => ({ error: secret }), diagnosticHttpStatusCode: () => undefined,
    emitProviderRequestTimelineEvent: () => {}, emitCoreModelRequestEndedDiagnosticEvent: () => effects.push('end'),
    dispatchModelCallEndedHook: () => {},
    observeOutputMessageContent: () => effects.push('chunk'), responseStreamChunkByteLength: () => 3,
    observeModelCallTerminalMessage: () => effects.push('result'), cloneDiagnosticContentValue: x => x,
    utf8JsonByteLength: () => 3,
  };
  const supportStart = s.indexOf('// operator-provider-timing:start');
  const supportEnd = s.indexOf('// operator-provider-timing:end');
  const support = supportStart < 0 ? '' : s.slice(supportStart, supportEnd);
  const api = vm.runInNewContext(`${support}\n${names.map(n => extract(s, n)).join('\n')}\n({${names.join(',')}})`, deps);
  const observer = () => ({ state: { responseStreamBytes: 0, contentCapture: { outputMessages: true } }, sizeTimingFields: () => ({}), usageField: () => ({}), completedContent: () => secret });
  const start = limit => api.createModelLifecycle({ ctx: { nextCallId: () => secret, trace: secret }, createObserver: observer, requestTimeoutMs: limit, options: { prompt: secret, headers: { Authorization: secret } } });
  return { logs, effects, api, start, secret, clock: value => { now = value; } };
}
test('start, first chunk once, terminal once; secret-bearing input stays out of logs', () => {
  const h = harness(transform(source));
  const call = h.start(120000);
  h.clock(1125); h.api.observeResponseChunk(call.observer.state, call.startedAt, { text: h.secret });
  h.clock(1150); h.api.observeResponseChunk(call.observer.state, call.startedAt, { text: h.secret });
  h.clock(1200); call.emitCompleted(); call.emitCompleted();
  assert.equal(h.logs.length, 3);
  assert.deepEqual(h.logs.map(line => JSON.parse(line.slice(line.indexOf('{')))), [
    { phase: 'start', call: 1, elapsedMs: 0, requestTimeoutMs: 120000 },
    { phase: 'first', call: 1, elapsedMs: 125 },
    { phase: 'completed', call: 1, elapsedMs: 200 },
  ]);
  assert.equal(h.logs.join('').includes(h.secret), false);
  assert.equal(call.observer.state.timeToFirstByteMs, 125);
  assert.deepEqual(h.effects, ['start', 'chunk', 'chunk', 'end']);
});
test('final-result only, failure before content, separate calls and invalid timeout', () => {
  const h = harness(transform(source)), first = h.start(h.secret), second = h.start(9000);
  h.clock(1010); h.api.observeResultMessageContent(first.observer.state, first.startedAt, { text: h.secret });
  h.clock(1020); first.emitCompleted(); second.emitError(new Error(h.secret));
  assert.equal(h.logs.length, 5);
  const records = h.logs.map(line => JSON.parse(line.slice(line.indexOf('{'))));
  assert.equal(records[0].requestTimeoutMs, null);
  assert.deepEqual(records.map(x => [x.phase, x.call]), [['start', 1], ['start', 2], ['first', 1], ['completed', 1], ['error', 2]]);
  assert.equal(h.logs.join('').includes(h.secret), false);
});
test('logging failures never change observer behavior', () => {
  const h = harness(transform(source), true), call = h.start(120000);
  h.api.observeResponseChunk(call.observer.state, call.startedAt, { text: h.secret });
  call.emitError(new Error(h.secret));
  assert.deepEqual(h.effects, ['start', 'chunk', 'end']);
});
if (!baseline) test('exact pins, repeat application, rejected source and instrument drift, full module syntax', () => {
  const changed = transform(source);
  assert.equal(transform(changed), changed);
  for (const name of names) assert.throws(() => transform(source.replace(`function ${name}(`, `function ${name}Drift(`)), /unsupported/i);
  assert.throws(() => transform(changed.replace('requestTimeoutMs: limit', 'requestTimeoutMs: 3')), /unsupported/i);
  const checked = spawnSync(process.execPath, ['--input-type=module', '--check'], { input: changed, encoding: 'utf8', env: { PATH: '/usr/bin:/bin', TMPDIR: '/private/tmp' } });
  assert.equal(checked.status, 0, checked.stderr);
});
if (!baseline) test('CLI creates protected output and refuses to replace source or output', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'operator-provider-timing-'));
  try {
    const input = path.join(directory, 'input.js'), output = path.join(directory, 'output.js');
    writeFileSync(input, source);
    const run = target => spawnSync(process.execPath, [fileURLToPath(new URL('./apply.mjs', import.meta.url)), input, target], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', TMPDIR: '/private/tmp' } });
    assert.equal(run(output).status, 0);
    assert.equal(readFileSync(output, 'utf8'), transform(source));
    assert.equal(statSync(output).mode & 0o777, 0o600);
    assert.notEqual(run(output).status, 0);
    assert.notEqual(run(input).status, 0);
    assert.equal(readFileSync(input, 'utf8'), source);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
