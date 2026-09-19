import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { patchNativeGatewayLoopExport } from '../export.mjs';

const source = readFileSync(new URL('../../../../../build/runtime-recovery/openclaw-source/package/dist/run-CrJnbDWP.js', import.meta.url), 'utf8');
const originalExport = 'export { runGatewayCommand };';
const nativeExport = 'export { runGatewayCommand, runGatewayLoop };';

test('exposes actual upstream lifecycle without changing its implementation', () => {
  const result = patchNativeGatewayLoopExport(source);
  assert.equal(result, source.replace(originalExport, nativeExport));
  assert.match(result, /requestHotReloadRecovery: eagerLifecycleRuntime.requestGatewayRestartWithSignalAdmission/);
  assert.match(result, /resetGatewayRestartStateForInProcessRestart\(\)/);
  assert.match(result, /await waitForGatewayActiveWork/);
});

test('repeated packaging makes no further change', () => {
  const result = patchNativeGatewayLoopExport(source);
  assert.equal(patchNativeGatewayLoopExport(result), result);
});

test('refuses missing or duplicated exports and changed lifecycle contract', () => {
  for (const changed of [
    source.replace(originalExport, ''), source + originalExport,
    source.replace('async function runGatewayLoop(params)', 'async function changedLoop(params)'),
    source.replace('params.ownsProcessLifecycle === true', 'true'),
    source.replace('params.runtime.exit(code)', 'process.exit(code)'),
    source.replace('requestHotReloadRecovery: eagerLifecycleRuntime.requestGatewayRestartWithSignalAdmission', 'requestHotReloadRecovery: undefined'),
  ]) assert.throws(() => patchNativeGatewayLoopExport(changed), /Pinned OpenClaw lifecycle/);
});
