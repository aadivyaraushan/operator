import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {startEmbeddedRuntime} from '../../host/start.mjs';

function fixture(t, fail = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'operator-embedded-host-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const stateDirectory = path.join(root, 'state');
  const runtimeDirectory = path.join(root, 'runtime');
  fs.mkdirSync(path.join(runtimeDirectory, 'openclaw/dist'), {recursive: true});
  fs.writeFileSync(path.join(runtimeDirectory, 'manifest.json'), JSON.stringify({gatewayModule: 'dist/server-start.js', lifecycleModule: 'dist/run.js'}));
  fs.writeFileSync(path.join(runtimeDirectory, 'openclaw/dist/run.js'), `
    import assert from 'node:assert/strict';
    export async function runGatewayLoop(params) {
      assert.equal(params.ownsProcessLifecycle, false);
      assert.equal(params.lockPort, 19123);
      assert.equal(process.env.OPENCLAW_NO_RESPAWN, '1');
      const recovery = () => ({status: 'accepted'});
      const server = await params.start({processStartedAt: 11, startupStartedAt: 22, requestHotReloadRecovery: recovery});
      assert.ok(server);
      if (process.env.OPERATOR_TEST_LOOP_EXIT === '1') params.runtime.exit(1);
    }
  `);
  fs.writeFileSync(path.join(runtimeDirectory, 'openclaw/package.json'), '{"type":"module"}');
  fs.writeFileSync(path.join(runtimeDirectory, 'openclaw/dist/server-start.js'), `
    import fs from 'node:fs';
    export async function startGatewayServerCore(port, options) {
      ${fail ? 'throw new Error(options.auth.token);' : ''}
      fs.writeFileSync(process.env.OPENCLAW_STATE_DIR + '/observed.json', JSON.stringify({port, options, recovery: typeof options.hotReloadRecovery, gatewayPort: process.env.OPENCLAW_GATEWAY_PORT, lockDirectory: process.env.OPERATOR_STATE_LOCK_DIR, cacheHome: process.env.XDG_CACHE_HOME}));
      return {startupSettled: Promise.resolve()};
    }
  `);
  return {stateDirectory, runtimeDirectory, gatewayToken: 'synthetic-vault-token', runID: 'first', statusPath: path.join(stateDirectory, 'native-runtime-status.json'), requiredGatewayPort: 19123};
}

test('native host uses actual package entry and vault token, then marks matching run ready', async t => {
  const input = fixture(t);
  await startEmbeddedRuntime(input);
  const status = JSON.parse(fs.readFileSync(input.statusPath));
  assert.equal(status.runID, input.runID);
  assert.equal(status.status, 'ready');
  const observed = JSON.parse(fs.readFileSync(path.join(input.stateDirectory, 'observed.json')));
  assert.equal(observed.port, 19123);
  assert.equal(observed.gatewayPort, '19123');
  assert.equal(observed.lockDirectory, path.join(input.stateDirectory, 'locks'));
  assert.equal(observed.cacheHome, path.join(input.stateDirectory, 'cache'));
  assert.deepEqual(observed.options.auth, {mode: 'token', token: input.gatewayToken});
  assert.equal(observed.options.bind, 'loopback');
  assert.equal(observed.recovery, 'function');
  assert.equal(observed.options.startupStartedAt, 22);
  assert.equal(observed.options.processStartedAt, 11);
});

test('upstream exit request records failure without exiting the embedding app', async t => {
  const input = fixture(t);
  process.env.OPERATOR_TEST_LOOP_EXIT = '1';
  t.after(() => delete process.env.OPERATOR_TEST_LOOP_EXIT);
  await startEmbeddedRuntime(input);
  assert.equal(JSON.parse(fs.readFileSync(input.statusPath)).status, 'failed');
});

test('reopening preserves configuration and authentication files', async t => {
  const input = fixture(t);
  await startEmbeddedRuntime(input);
  const configPath = path.join(input.stateDirectory, 'openclaw.json');
  const config = fs.readFileSync(configPath, 'utf8');
  const authPath = path.join(input.stateDirectory, 'synthetic-auth.json');
  fs.writeFileSync(authPath, 'keep-synthetic-auth');
  await startEmbeddedRuntime({...input, runID: 'reopened'});
  assert.equal(fs.readFileSync(configPath, 'utf8'), config);
  assert.equal(fs.readFileSync(authPath, 'utf8'), 'keep-synthetic-auth');
  assert.equal(JSON.parse(fs.readFileSync(input.statusPath)).runID, 'reopened');
});

test('startup failure replaces stale ready state without exposing the vault token', async t => {
  const input = fixture(t, true);
  fs.mkdirSync(input.stateDirectory);
  fs.writeFileSync(input.statusPath, '{"runID":"old","status":"ready"}');
  await startEmbeddedRuntime(input);
  const raw = fs.readFileSync(input.statusPath, 'utf8');
  assert.equal(JSON.parse(raw).status, 'failed');
  assert.equal(JSON.parse(raw).runID, input.runID);
  assert.ok(!raw.includes(input.gatewayToken));
  assert.equal(JSON.parse(raw).diagnostic.name, 'Error');
  assert.ok(JSON.parse(raw).diagnostic.frames.some(frame => frame.startsWith('server-start.js:')));
  assert.ok(!raw.includes(input.runtimeDirectory));
});

test('missing runtime bundle records failure without a second diagnostic error', async t => {
  const input = fixture(t);
  fs.rmSync(input.runtimeDirectory, {recursive: true});
  await startEmbeddedRuntime(input);
  const raw = fs.readFileSync(input.statusPath, 'utf8');
  const status = JSON.parse(raw);
  assert.equal(status.status, 'failed');
  assert.deepEqual(status.diagnostic.frames, []);
  assert.ok(!raw.includes(input.runtimeDirectory));
  assert.ok(!raw.includes(input.gatewayToken));
});
