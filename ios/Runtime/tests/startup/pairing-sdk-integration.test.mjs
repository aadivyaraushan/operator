import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

// Explicit local pinned package only. No downloads, Gateway, accounts or real store.
const packageRoot = process.env.OPERATOR_TEST_OPENCLAW_PACKAGE;
test('real SDK approves sequential native roles and leaves foreign identity pending',
  { skip: !packageRoot, timeout: 20000 }, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'operator-sdk-integration-'));
    let child;
    try {
      const dist = join(packageRoot, 'dist');
      const apiURL = pathToFileURL(join(dist, 'plugin-sdk/device-bootstrap.js')).href;
      const { listDevicePairing } = await import(apiURL);
      // Request creation is a test fixture using the pinned upstream implementation;
      // production helper imports only the public SDK, never this internal module.
      let requestDevicePairing;
      for (const name of await readdir(dist)) {
        if (!/^device-pairing-[A-Za-z0-9_]+\.js$/.test(name)) continue;
        const exports = await import(pathToFileURL(join(dist, name)).href);
        requestDevicePairing = Object.values(exports).find(value =>
          typeof value === 'function' && value.name === 'requestDevicePairing');
        if (requestDevicePairing) break;
      }
      assert.equal(typeof requestDevicePairing, 'function');
      const identity = { deviceId: 'synthetic-operator', publicKey: 'synthetic-public-key' };
      const state = join(directory, 'state');
      await requestDevicePairing({ ...identity, publicKey: 'foreign-key', role: 'operator', scopes: ['operator.read'] }, state);
      // Use a distinct foreign device so the real store does not supersede our own request.
      await requestDevicePairing({ deviceId: 'foreign-device', publicKey: 'foreign-key', role: 'operator', scopes: ['operator.read'] }, state);
      await requestDevicePairing({ ...identity, role: 'operator', scopes: ['operator.read'] }, state);
      const source = await readFile(new URL('../../guest/runtime-start/device-pairing/approve-app-device.mjs', import.meta.url), 'utf8');
      const installedEntry = 'file:///usr/local/lib/node_modules/openclaw/dist/plugin-sdk/device-bootstrap.js';
      assert.ok(source.includes(installedEntry));
      const script = join(directory, 'helper.mjs');
      await writeFile(script, source.replace(installedEntry, apiURL));
      child = spawn(process.execPath, [script], { env: {
        ...process.env, OPENCLAW_STATE_DIR: state,
        OPENCLAW_EXPECTED_DEVICE_ID: identity.deviceId,
        OPENCLAW_EXPECTED_PUBLIC_KEY: identity.publicKey,
        OPENCLAW_GATEWAY_PARENT_PID: String(process.pid),
      }, stdio: ['ignore', 'pipe', 'pipe'] });
      let errors = '';
      child.stderr.on('data', data => { errors += data; });
      const exit = new Promise(resolve => child.once('exit', (code, signal) => resolve({ code, signal })));
      const deadline = Date.now() + 12000;
      let operatorApproved = false;
      while (Date.now() < deadline && child.exitCode === null) {
        const snapshot = await listDevicePairing(state);
        operatorApproved = snapshot.paired.some(device => device.deviceId === identity.deviceId && device.roles?.includes('operator'));
        if (operatorApproved) break;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      assert.ok(operatorApproved, errors);
      assert.equal(child.exitCode, null, 'operator-only approval must not finish helper');
      await requestDevicePairing({ ...identity, role: 'node', scopes: [] }, state);
      const timer = setTimeout(() => child.kill('SIGTERM'), 6000);
      const result = await exit;
      clearTimeout(timer);
      assert.deepEqual(result, { code: 0, signal: null }, errors);
      const final = await listDevicePairing(state);
      const device = final.paired.find(item => item.deviceId === identity.deviceId);
      assert.equal(device.publicKey, identity.publicKey);
      assert.ok(device.roles.includes('operator') && device.roles.includes('node'));
      assert.ok(final.pending.some(item => item.deviceId === 'foreign-device'));
      assert.ok(!final.paired.some(item => item.deviceId === 'foreign-device'));
    } finally {
      if (child && child.exitCode === null && child.signalCode === null) {
        const stopped = new Promise(resolve => child.once('exit', resolve));
        child.kill('SIGTERM');
        await stopped;
      }
      await rm(directory, { recursive: true, force: true });
    }
  });
