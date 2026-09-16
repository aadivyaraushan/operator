import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {prepareState, refreshWorkspaceGuidance} from '../../gateway/state.mjs';
import {OPERATOR_GUIDANCE_END, OPERATOR_GUIDANCE_START, OPERATOR_WORKSPACE_GUIDANCE} from '../../package/workspace-guidance.mjs';

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
  assert.equal(config.agents.defaults.workspace, undefined);
  assert.equal(config.agents.defaults.fastModeDefault, 'auto');
  assert.deepEqual(config.agents.defaults.contextPruning, {mode: 'cache-ttl', ttl: '5m'});
  assert.deepEqual(config.tools.web.search.openaiCodex, {enabled: true, mode: 'live'});
  assert.ok(fs.statSync(path.join(state, 'workspace')).isDirectory());
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

test('relocates an app-managed workspace and preserves structured configuration', t => {
  const state = sandbox(t);
  const oldState = path.join(path.dirname(state), 'previous-container', 'Operator', 'openclaw');
  const oldWorkspace = path.join(oldState, 'workspace');
  fs.mkdirSync(oldWorkspace, {recursive: true});
  fs.writeFileSync(path.join(oldWorkspace, 'MEMORY.md'), 'preserved workspace data');
  const saved = JSON.stringify({
    agents: {defaults: {workspace: oldWorkspace, model: {primary: 'openai/test-model'}}},
    marker: 'keep-settings-and-login',
    custom: {escaped: 'line one\nline two', values: ['first', {nested: true}]}
  });
  fs.mkdirSync(state);
  const configPath = path.join(state, 'openclaw.json');
  fs.writeFileSync(configPath, saved);
  const account = path.join(state, 'auth-profiles.json');
  fs.writeFileSync(account, 'preserved-auth-profile');

  assert.equal(prepareState(state).created, false);

  const migrated = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  assert.equal(migrated.agents.defaults.workspace, undefined);
  assert.equal(migrated.agents.defaults.model.primary, 'openai/test-model');
  assert.equal(migrated.marker, 'keep-settings-and-login');
  assert.deepEqual(migrated.custom, {escaped: 'line one\nline two', values: ['first', {nested: true}]});
  assert.equal(fs.readFileSync(path.join(state, 'workspace', 'MEMORY.md'), 'utf8'), 'preserved workspace data');
  assert.equal(fs.readFileSync(account, 'utf8'), 'preserved-auth-profile');
  assert.equal(fs.readFileSync(path.join(oldWorkspace, 'MEMORY.md'), 'utf8'), 'preserved workspace data');
});

test('a vanished app-managed workspace with nothing to recover is dropped so the runtime can start', t => {
  // The container moved before OpenClaw ever seeded the workspace: the old
  // path is gone and the new default is empty. Refusing here would brick the
  // install, since nothing on an iPhone can restore a container directory.
  const state = sandbox(t);
  const oldWorkspace = path.join(path.dirname(state), 'previous-container', 'Operator', 'openclaw', 'workspace');
  fs.mkdirSync(state);
  const configPath = path.join(state, 'openclaw.json');
  fs.writeFileSync(configPath, JSON.stringify({agents: {defaults: {workspace: oldWorkspace, model: {primary: 'openai/test-model'}}}, marker: 'keep'}));

  assert.equal(prepareState(state).created, false);
  const migrated = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  assert.equal(migrated.agents.defaults.workspace, undefined);
  assert.equal(migrated.agents.defaults.model.primary, 'openai/test-model');
  assert.equal(migrated.marker, 'keep');
  assert.ok(fs.statSync(path.join(state, 'workspace')).isDirectory());
});

test('a workspace the owner pointed somewhere else is not app-managed and is left alone', t => {
  const state = sandbox(t);
  const first = prepareState(state);
  const elsewhere = path.join(path.dirname(state), 'chosen-workspace');
  fs.mkdirSync(elsewhere);
  const config = JSON.parse(fs.readFileSync(first.configPath, 'utf8'));
  config.agents.defaults.workspace = elsewhere;
  const saved = JSON.stringify(config, null, 2);
  fs.writeFileSync(first.configPath, saved);
  assert.equal(prepareState(state).created, false);
  assert.equal(fs.readFileSync(first.configPath, 'utf8'), saved);
});

test('existing unusual configuration is preserved for OpenClaw to validate, never reset', t => {
  const state = sandbox(t);
  fs.mkdirSync(state);
  const configPath = path.join(state, 'openclaw.json');
  fs.writeFileSync(configPath, 'broken or partial configuration');
  assert.equal(prepareState(state).created, false);
  assert.equal(fs.readFileSync(configPath, 'utf8'), 'broken or partial configuration');
});

test('existing settings gain automatic fast mode without replacing credentials or explicit preferences', t => {
  const state = sandbox(t);
  fs.mkdirSync(state);
  const configPath = path.join(state, 'openclaw.json');
  const saved = {gateway: {auth: {token: 'synthetic-secret'}}, agents: {defaults: {model: {primary: 'test-model'}}}, custom: ['keep']};
  fs.writeFileSync(configPath, JSON.stringify(saved));
  prepareState(state);
  const pruning = {mode: 'cache-ttl', ttl: '5m'};
  assert.deepEqual(JSON.parse(fs.readFileSync(configPath)), {...saved, agents: {defaults: {...saved.agents.defaults, fastModeDefault: 'auto', contextPruning: pruning}}, tools: {web: {search: {openaiCodex: {enabled: true, mode: 'live'}}}}});
  const stable = fs.readFileSync(configPath, 'utf8');
  prepareState(state);
  assert.equal(fs.readFileSync(configPath, 'utf8'), stable);
  for (const preference of [true, false, 'auto']) {
    const explicit = JSON.stringify({...saved, agents: {defaults: {fastModeDefault: preference, contextPruning: pruning}}, tools: {web: {search: {openaiCodex: {enabled: true, mode: 'live'}}}}});
    fs.writeFileSync(configPath, explicit);
    prepareState(state);
    assert.equal(fs.readFileSync(configPath, 'utf8'), explicit);
  }
  // An owner who turned pruning off, or tuned it, keeps that.
  for (const chosen of [{mode: 'off'}, {mode: 'cache-ttl', ttl: '1h'}]) {
    const explicit = JSON.stringify({...saved, agents: {defaults: {fastModeDefault: 'auto', contextPruning: chosen}}, tools: {web: {search: {openaiCodex: {enabled: true, mode: 'live'}}}}});
    fs.writeFileSync(configPath, explicit);
    prepareState(state);
    assert.equal(fs.readFileSync(configPath, 'utf8'), explicit);
  }
});

test('storage errors fail instead of silently creating another state directory', t => {
  const state = sandbox(t);
  fs.writeFileSync(state, 'not a directory');
  assert.throws(() => prepareState(state));
  assert.equal(fs.readFileSync(state, 'utf8'), 'not a directory');
});

test('search defaults preserve explicit disables, providers, restrictions and unusual settings', t => {
  const state = sandbox(t);
  fs.mkdirSync(state);
  const configPath = path.join(state, 'openclaw.json');
  for (const search of [
    {enabled: false},
    {openaiCodex: {enabled: false}},
    {provider: 'brave', apiKey: 'synthetic-key'},
    {openaiCodex: {enabled: true, mode: 'cached', allowedDomains: ['example.com']}},
    null, [], false
  ]) {
    const saved = JSON.stringify({agents: {defaults: {fastModeDefault: 'auto', contextPruning: {mode: 'off'}}}, tools: {web: {search}}, marker: 'keep'});
    fs.writeFileSync(configPath, saved);
    prepareState(state);
    assert.equal(fs.readFileSync(configPath, 'utf8'), saved);
  }
});

test('search migration fills only missing native options and keeps saved data', t => {
  const state = sandbox(t);
  fs.mkdirSync(state);
  const configPath = path.join(state, 'openclaw.json');
  const saved = {agents: {defaults: {fastModeDefault: 'auto', contextPruning: {mode: 'off'}}}, tools: {web: {fetch: {enabled: true}, search: {openaiCodex: {allowedDomains: ['example.com'], mode: 'cached'}}}}, marker: 'keep'};
  fs.writeFileSync(configPath, JSON.stringify(saved));
  prepareState(state);
  const expected = structuredClone(saved);
  expected.tools.web.search.openaiCodex.enabled = true;
  assert.deepEqual(JSON.parse(fs.readFileSync(configPath)), expected);
  const stable = fs.readFileSync(configPath, 'utf8');
  prepareState(state);
  assert.equal(fs.readFileSync(configPath, 'utf8'), stable);
});

test('a legacy Operator section is replaced with the current wording and gains markers, keeping the rest', t => {
  const state = sandbox(t);
  prepareState(state);
  const file = path.join(state, 'workspace', 'AGENTS.md');
  const owners = '# Rules for your phone agent\n\nReply in my voice: casual, short.\n';
  fs.writeFileSync(file, `${owners}\n## When you cannot carry something out\n\nOn this phone you have no tool that sends a message.\n`);
  assert.equal(prepareState(state).guidanceRefreshed, true);
  const refreshed = fs.readFileSync(file, 'utf8');
  assert.ok(refreshed.startsWith(owners.trimEnd()), 'the owner\'s part survives');
  assert.ok(refreshed.includes(OPERATOR_GUIDANCE_START) && refreshed.includes(OPERATOR_GUIDANCE_END));
  assert.ok(refreshed.includes('PERMISSION_DENIED'));
  assert.ok(!refreshed.includes('you have no tool that sends a message'));
  assert.equal(prepareState(state).guidanceRefreshed, false, 'a second start changes nothing');
});

test('a marked section is replaced in place and text the owner wrote after it is kept', t => {
  const state = sandbox(t);
  prepareState(state);
  const file = path.join(state, 'workspace', 'AGENTS.md');
  const stale = OPERATOR_WORKSPACE_GUIDANCE.trim().replace('PERMISSION_DENIED', 'SOME_OLD_CODE');
  fs.writeFileSync(file, `# Rules\n\n${stale}\n\n## Quiet hours\n\nNever text after 23:00.\n`);
  assert.equal(refreshWorkspaceGuidance(path.join(state, 'workspace')), true);
  const refreshed = fs.readFileSync(file, 'utf8');
  assert.ok(refreshed.includes('PERMISSION_DENIED') && !refreshed.includes('SOME_OLD_CODE'));
  assert.ok(refreshed.endsWith('## Quiet hours\n\nNever text after 23:00.\n'));
});

test('a workspace with no Operator section, or no AGENTS.md, is left alone', t => {
  const state = sandbox(t);
  prepareState(state);
  const workspace = path.join(state, 'workspace');
  assert.equal(refreshWorkspaceGuidance(workspace), false);
  fs.writeFileSync(path.join(workspace, 'AGENTS.md'), '# Mine\n');
  assert.equal(refreshWorkspaceGuidance(workspace), false);
  assert.equal(fs.readFileSync(path.join(workspace, 'AGENTS.md'), 'utf8'), '# Mine\n');
});
