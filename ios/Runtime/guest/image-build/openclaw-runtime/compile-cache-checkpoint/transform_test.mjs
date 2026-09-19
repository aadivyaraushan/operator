import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { transform } from './transform.mjs';

const realPath = new URL('../../../../../build/runtime-recovery/openclaw-source/package/dist/server-start-BNcm1gUN.js', import.meta.url);
const realSource = readFileSync(realPath, 'utf8');
const context = `\tkernel.setPostAttachHandles(postAttachHandles, startupPluginRuntimeClaim);
\tstartupTrace.detail("memory.ready", collectGatewayProcessMemoryUsageMb());
\tstartupTrace.mark("ready");
\tif (sidecarStartup === "defer") log.info("gateway ready");
\tfinishGatewayRestartTrace("restart.ready", collectGatewayProcessMemoryUsageMb());`;
const source = `import { createRequire } from "node:module";\n${context}\n`;

test('transforms the real pinned public module and remains syntactically valid', () => {
  const changed = transform(realSource);
  assert.equal((changed.match(/flushCompileCache\(\);/g) ?? []).length, 1);
  assert.equal(spawnSync(process.execPath, ['--check', '--input-type=module'], { input: changed }).status, 0);
});

test('inserts exactly one checkpoint before ready and preserves following order', () => {
  const changed = transform(source);
  assert.match(changed, /memory\.ready.*compile-cache-flush-start/s);
  assert.ok(changed.indexOf('compile-cache-flush-end') < changed.indexOf('startupTrace.mark("ready");'));
  assert.ok(changed.indexOf('startupTrace.mark("ready");') < changed.indexOf('gateway ready'));
  assert.ok(changed.indexOf('gateway ready') < changed.indexOf('finishGatewayRestartTrace'));
});

test('second transform is unchanged only for the exact transformed context', () => {
  const changed = transform(source);
  assert.deepEqual(transform(changed), changed);
  const reordered = changed.replace(
    '\tstartupTrace.mark("compile-cache-flush-start");\n\tflushCompileCache();',
    '\tflushCompileCache();\n\tstartupTrace.mark("compile-cache-flush-start");',
  );
  assert.throws(() => transform(reordered), /Unsupported compile-cache checkpoint source/);
  assert.throws(() => transform(changed.replace('finishGatewayRestartTrace', 'changedFinishGatewayRestartTrace')), /Unsupported compile-cache checkpoint source/);
});

test('rejects arbitrary ready anchors and missing or duplicate pinned anchors', () => {
  for (const bad of [
    'import { createRequire } from "node:module";\nstartupTrace.mark("ready");\n',
    source.replace('startupTrace.mark("ready");', ''),
    source.replace(context, `${context}\n${context}`),
    source.replace('import { createRequire } from "node:module";', 'import { createRequire } from "node:module";\nimport { createRequire } from "node:module";'),
  ]) assert.throws(() => transform(bad), /Unsupported compile-cache checkpoint source/);
});

test('rejects extra ready or checkpoint markers outside the pinned context', () => {
  assert.throws(() => transform(source + 'startupTrace.mark("ready");\n'), /Unsupported/);
  assert.throws(() => transform(transform(source) + 'startupTrace.mark("compile-cache-flush-start");\n'), /Unsupported/);
});

test('executes one synchronous flush in the existing startup order', () => {
  const events = [];
  const body = transform(source).replace('import { createRequire, flushCompileCache } from "node:module";\n', '');
  new Function('kernel', 'postAttachHandles', 'startupPluginRuntimeClaim', 'startupTrace',
    'collectGatewayProcessMemoryUsageMb', 'flushCompileCache', 'sidecarStartup', 'log',
    'finishGatewayRestartTrace', body)(
    { setPostAttachHandles: () => events.push('handles') }, {}, {},
    { detail: () => events.push('memory'), mark: name => events.push(name) },
    () => ({}), () => events.push('flush'), 'defer',
    { info: () => events.push('ready-log') }, () => events.push('restart-trace'));
  assert.deepEqual(events, ['handles', 'memory', 'compile-cache-flush-start', 'flush',
    'compile-cache-flush-end', 'ready', 'ready-log', 'restart-trace']);
});
