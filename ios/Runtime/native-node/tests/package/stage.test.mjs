import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {stageRuntime} from '../../package/stage.mjs';

test('packages the real entry contract and patches only the copied public package', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'operator-package-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const source = path.join(root, 'source');
  const output = path.join(root, 'output');
  fs.mkdirSync(path.join(source, 'dist'), {recursive: true});
  fs.mkdirSync(path.join(source, 'node_modules'));
  const searchModule = 'node_modules/@openclaw/ai/dist/openai-chatgpt-responses-BAJ4gq3i.mjs';
  fs.mkdirSync(path.dirname(path.join(source, searchModule)), {recursive: true});
  const searchSource = fs.readFileSync(new URL(`../../../../build/native-node/runtime/openclaw/${searchModule}`, import.meta.url), 'utf8');
  fs.writeFileSync(path.join(source, searchModule), searchSource);
  fs.writeFileSync(path.join(source, 'package.json'), '{"name":"openclaw","version":"2026.9.1"}');
  fs.writeFileSync(path.join(source, 'dist/server-start-example.js'), 'export async function startGatewayServerCore() {}');
  const original = fs.readFileSync(new URL('../../../../build/native-node/runtime/openclaw/dist/openclaw-state-db-Bh3Bq87y.js', import.meta.url), 'utf8');
  fs.writeFileSync(path.join(source, 'dist/openclaw-state-db-Bh3Bq87y.js'), original);
  const lifecycle = fs.readFileSync(new URL('../../../../build/native-node/runtime/openclaw/dist/run-CrJnbDWP.js', import.meta.url), 'utf8');
  fs.writeFileSync(path.join(source, 'dist/run-CrJnbDWP.js'), lifecycle);
  // Fixtures come from the staged runtime under ios/build, so this needs a
  // completed bootstrap. Every staging patch is idempotent, so feeding an
  // already-patched module back in is a valid source.
  for (const name of ['state-database-coordinator-DKD8Uulb.js', 'main-session-restart-recovery--2blnuu5.js', 'transcript-events-BMaG3A_w.js', 'chat-D3QlhTHk.js', 'chat-send-handler-DBjXcn_1.js']) {
    fs.copyFileSync(new URL(`../../../../build/native-node/runtime/openclaw/dist/${name}`, import.meta.url), path.join(source, 'dist', name));
  }
  // The staged AGENTS.md already carries the Operator section, and staging
  // refuses a template that does; rebuild the upstream shape by cutting it.
  const templateSource = new URL('../../../../build/native-node/runtime/openclaw/docs/reference/templates/', import.meta.url);
  fs.cpSync(templateSource, path.join(source, 'docs/reference/templates'), {recursive: true});
  const stagedTemplate = fs.readFileSync(path.join(source, 'docs/reference/templates/AGENTS.md'), 'utf8');
  fs.writeFileSync(path.join(source, 'docs/reference/templates/AGENTS.md'), stagedTemplate.split('\n## When you cannot carry something out')[0] + '\n');
  fs.writeFileSync(path.join(source, 'private-account.json'), 'must-not-package');
  stageRuntime(source, output);
  assert.match(fs.readFileSync(path.join(output, 'openclaw', searchModule), 'utf8'), /\[native-search\] provider search completed/);
  assert.equal(fs.readFileSync(path.join(source, searchModule), 'utf8'), searchSource);
  assert.ok(fs.existsSync(path.join(output, 'entry.mjs')));
  assert.ok(fs.existsSync(path.join(output, 'host/start.mjs')));
  assert.ok(!fs.existsSync(path.join(output, 'openclaw/private-account.json')));
  assert.match(fs.readFileSync(path.join(output, 'openclaw/dist/openclaw-state-db-Bh3Bq87y.js'), 'utf8'), /Operator native ownership admission/);
  assert.equal(fs.readFileSync(path.join(source, 'dist/openclaw-state-db-Bh3Bq87y.js'), 'utf8'), original);
  assert.equal(JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'))).gatewayModule, 'dist/server-start-example.js');
  assert.equal(JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'))).lifecycleModule, 'dist/run-CrJnbDWP.js');
  assert.match(fs.readFileSync(path.join(output, 'openclaw/dist/run-CrJnbDWP.js'), 'utf8'), /export \{ runGatewayCommand, runGatewayLoop \};/);
  assert.ok(fs.existsSync(path.join(output, 'openclaw/dist/native-recovery-source-run.mjs')));
  assert.match(fs.readFileSync(path.join(output, 'openclaw/dist/main-session-restart-recovery--2blnuu5.js'), 'utf8'), /registerNativeRecoverySourceRun\(recoveryRunId, sourceRunId\)/);
  assert.match(fs.readFileSync(path.join(output, 'openclaw/dist/transcript-events-BMaG3A_w.js'), 'utf8'), /attachNativeRecoverySourceRunId\(messageWithRunId, normalizedRunId\)/);
  assert.equal(fs.readFileSync(path.join(output, 'openclaw/dist/chat-D3QlhTHk.js'), 'utf8').split('...operatorRecovery ? { operatorRecovery } : {}').length - 1, 2);
  assert.match(fs.readFileSync(path.join(output, 'openclaw/dist/chat-send-handler-DBjXcn_1.js'), 'utf8'), /request\.clientInfo\?\.id === "openclaw-ios"/);
  assert.ok(JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'))).patches.includes('native-recovery-source-run'));
  assert.ok(JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'))).patches.includes('native-ios-restart-safe-admission'));
  assert.equal(fs.readFileSync(path.join(source, 'dist/run-CrJnbDWP.js'), 'utf8'), lifecycle);
  assert.match(fs.readFileSync(path.join(output, 'openclaw/dist/state-database-coordinator-DKD8Uulb.js'), 'utf8'), /process\.env\.OPERATOR_STATE_LOCK_DIR/);
  assert.equal(fs.readFileSync(path.join(source, 'dist/state-database-coordinator-DKD8Uulb.js'), 'utf8'),
    fs.readFileSync(new URL('../../../../build/native-node/runtime/openclaw/dist/state-database-coordinator-DKD8Uulb.js', import.meta.url), 'utf8'));
  for (const name of fs.readdirSync(templateSource)) {
    // AGENTS.md is the one template the staged copy extends; see below.
    if (name === 'AGENTS.md') continue;
    assert.deepEqual(fs.readFileSync(path.join(output, 'openclaw/docs/reference/templates', name)),
      fs.readFileSync(new URL(name, templateSource)), `bundled workspace template ${name}`);
  }
  // OpenClaw writes AGENTS.md into a new workspace from this template and only
  // when it is missing, so guidance that is not in the template is absent from
  // every clean install. The staged copy carries the upstream body verbatim
  // plus the Operator section, and the public package is left untouched.
  const stagedAgents = fs.readFileSync(path.join(output, 'openclaw/docs/reference/templates/AGENTS.md'), 'utf8');
  const upstreamAgents = fs.readFileSync(path.join(source, 'docs/reference/templates/AGENTS.md'), 'utf8');
  assert.ok(stagedAgents.startsWith(upstreamAgents.trimEnd()), 'staged AGENTS.md must preserve the upstream template');
  assert.match(stagedAgents, /## When you cannot carry something out/);
  assert.match(stagedAgents, /never claim you have done something you have\nnot done/);
  assert.equal(fs.readFileSync(path.join(source, 'docs/reference/templates/AGENTS.md'), 'utf8'), upstreamAgents);
  assert.throws(() => stageRuntime(source, output), /exists/i);
});
