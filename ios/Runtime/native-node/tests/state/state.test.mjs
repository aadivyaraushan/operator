import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {prepareState} from '../../gateway/state.mjs';

function sandbox(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'operator-native-state-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  return path.join(directory, 'state');
}

test('first launch creates private loopback configuration and workspace', t => {
  const state = sandbox(t);
  const result = prepareState(state);
  const config = JSON.parse(fs.readFileSync(result.configPath, 'utf8'));
  assert.equal(result.created, true);
  assert.equal(config.gateway.bind, 'loopback');
  assert.equal(config.gateway.mode, 'local');
  assert.equal(config.gateway.auth.mode, 'token');
  assert.match(config.gateway.auth.token, /^[a-f0-9]{64}$/);
  assert.equal(config.agents.defaults.workspace, path.join(state, 'workspace'));
  assert.ok(fs.statSync(config.agents.defaults.workspace).isDirectory());
  assert.equal(fs.statSync(result.configPath).mode & 0o777, 0o600);
});

test('reopening preserves config, token, model and account files byte for byte', t => {
  const state = sandbox(t);
  const first = prepareState(state);
  const config = JSON.parse(fs.readFileSync(first.configPath, 'utf8'));
  config.agents.defaults.model = {primary: 'openai/test-model'};
  const saved = JSON.stringify(config, null, 2);
  fs.writeFileSync(first.configPath, saved);
  const account = path.join(state, 'auth-profiles.json');
  fs.writeFileSync(account, 'synthetic-account-fixture');
  assert.equal(prepareState(state).created, false);
  assert.equal(fs.readFileSync(first.configPath, 'utf8'), saved);
  assert.equal(fs.readFileSync(account, 'utf8'), 'synthetic-account-fixture');
});

test('existing unusual configuration is preserved for OpenClaw to validate, never reset', t => {
  const state = sandbox(t);
  fs.mkdirSync(state);
  const configPath = path.join(state, 'openclaw.json');
  fs.writeFileSync(configPath, 'broken or partial configuration');
  assert.equal(prepareState(state).created, false);
  assert.equal(fs.readFileSync(configPath, 'utf8'), 'broken or partial configuration');
});

test('storage errors fail instead of silently creating another state directory', t => {
  const state = sandbox(t);
  fs.writeFileSync(state, 'not a directory');
  assert.throws(() => prepareState(state));
  assert.equal(fs.readFileSync(state, 'utf8'), 'not a directory');
});

test('a workspace that vanished with its container is repointed and nothing else changes', t => {
  const state = sandbox(t);
  const first = prepareState(state);
  const config = JSON.parse(fs.readFileSync(first.configPath, 'utf8'));
  const gone = path.join(path.dirname(state), 'previous-container', 'openclaw', 'workspace');
  config.agents.defaults.workspace = gone;
  config.agents.defaults.model = {primary: 'openai/test-model'};
  config.meta = {lastTouchedVersion: '2026.9.1'};
  fs.writeFileSync(first.configPath, JSON.stringify(config, null, 2));
  const result = prepareState(state);
  assert.equal(result.created, false);
  assert.equal(result.workspaceRepointed, true);
  const repointed = JSON.parse(fs.readFileSync(first.configPath, 'utf8'));
  assert.equal(repointed.agents.defaults.workspace, path.join(state, 'workspace'));
  assert.deepEqual(repointed.agents.defaults.model, {primary: 'openai/test-model'});
  assert.deepEqual(repointed.meta, {lastTouchedVersion: '2026.9.1'});
  assert.equal(repointed.gateway.auth.token, config.gateway.auth.token);
  assert.equal(fs.statSync(first.configPath).mode & 0o777, 0o600);
  assert.ok(!fs.existsSync(`${first.configPath}.repoint`));
});

test('a workspace the owner pointed elsewhere is left alone while it exists', t => {
  const state = sandbox(t);
  const first = prepareState(state);
  const elsewhere = path.join(path.dirname(state), 'chosen-workspace');
  fs.mkdirSync(elsewhere);
  const config = JSON.parse(fs.readFileSync(first.configPath, 'utf8'));
  config.agents.defaults.workspace = elsewhere;
  const saved = JSON.stringify(config, null, 2);
  fs.writeFileSync(first.configPath, saved);
  assert.equal(prepareState(state).workspaceRepointed, false);
  assert.equal(fs.readFileSync(first.configPath, 'utf8'), saved);
});
