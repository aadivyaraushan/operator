import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

test('bootstrap passes preserved state to the gateway on each app launch', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'operator-native-reopen-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  const state = path.join(directory, 'openclaw-state');
  fs.mkdirSync(state);
  const saved = JSON.stringify({gateway: {auth: {token: 'synthetic-saved-token'}}, marker: 'keep-model-and-login'});
  fs.writeFileSync(path.join(state, 'openclaw.json'), saved);
  const dist = path.join(directory, 'openclaw/dist');
  fs.mkdirSync(dist, {recursive: true});
  fs.writeFileSync(path.join(directory, 'openclaw/package.json'), '{"type":"module"}');
  // Only the gateway is replaced here: actual bootstrap and filesystem run in a new process.
  fs.writeFileSync(path.join(dist, 'server-start-BNcm1gUN.js'), `
    import fs from 'node:fs';
    export async function startGatewayServerCore() {
      fs.writeFileSync(process.env.OPENCLAW_STATE_DIR + '/observed.json', fs.readFileSync(process.env.OPENCLAW_CONFIG_PATH));
    }
  `);
  for (const run of ['first', 'reopened']) {
    const child = spawnSync(process.execPath, [fileURLToPath(new URL('../../gateway/bootstrap.mjs', import.meta.url))], {
      env: {...process.env, OPERATOR_PROBE_DIRECTORY: directory, OPERATOR_PROBE_RUN: run}, encoding: 'utf8', timeout: 10000
    });
    assert.equal(child.status, 0, child.stderr);
    const result = JSON.parse(fs.readFileSync(path.join(directory, 'openclaw-result.json')));
    assert.equal(result.status, 'pass');
    assert.equal(result.run, run);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(state, 'observed.json'))), {
      ...JSON.parse(saved), agents: {defaults: {fastModeDefault: 'auto'}},
      tools: {web: {search: {openaiCodex: {enabled: true, mode: 'live'}}}}
    });
  }
});
