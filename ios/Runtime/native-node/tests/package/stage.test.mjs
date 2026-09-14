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
  fs.writeFileSync(path.join(source, 'package.json'), '{"name":"openclaw","version":"2026.9.1"}');
  fs.writeFileSync(path.join(source, 'dist/server-start-example.js'), 'export async function startGatewayServerCore() {}');
  const original = fs.readFileSync(new URL('../../../../build/runtime-recovery/openclaw-source/package/dist/openclaw-state-db-Bh3Bq87y.js', import.meta.url), 'utf8');
  fs.writeFileSync(path.join(source, 'dist/openclaw-state-db-Bh3Bq87y.js'), original);
  const lifecycle = fs.readFileSync(new URL('../../../../build/runtime-recovery/openclaw-source/package/dist/run-CrJnbDWP.js', import.meta.url), 'utf8');
  fs.writeFileSync(path.join(source, 'dist/run-CrJnbDWP.js'), lifecycle);
  const templateSource = new URL('../../../../build/runtime-recovery/r6-official-codex-runtime/extracted/usr/local/lib/node_modules/openclaw/docs/reference/templates/', import.meta.url);
  fs.cpSync(templateSource, path.join(source, 'docs/reference/templates'), {recursive: true});
  fs.writeFileSync(path.join(source, 'private-account.json'), 'must-not-package');
  stageRuntime(source, output);
  assert.ok(fs.existsSync(path.join(output, 'entry.mjs')));
  assert.ok(fs.existsSync(path.join(output, 'host/start.mjs')));
  assert.ok(!fs.existsSync(path.join(output, 'openclaw/private-account.json')));
  assert.match(fs.readFileSync(path.join(output, 'openclaw/dist/openclaw-state-db-Bh3Bq87y.js'), 'utf8'), /Operator native ownership admission/);
  assert.equal(fs.readFileSync(path.join(source, 'dist/openclaw-state-db-Bh3Bq87y.js'), 'utf8'), original);
  assert.equal(JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'))).gatewayModule, 'dist/server-start-example.js');
  assert.equal(JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'))).lifecycleModule, 'dist/run-CrJnbDWP.js');
  assert.match(fs.readFileSync(path.join(output, 'openclaw/dist/run-CrJnbDWP.js'), 'utf8'), /export \{ runGatewayCommand, runGatewayLoop \};/);
  assert.equal(fs.readFileSync(path.join(source, 'dist/run-CrJnbDWP.js'), 'utf8'), lifecycle);
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
  const upstreamAgents = fs.readFileSync(new URL('AGENTS.md', templateSource), 'utf8');
  assert.ok(stagedAgents.startsWith(upstreamAgents.trimEnd()), 'staged AGENTS.md must preserve the upstream template');
  assert.match(stagedAgents, /## When you cannot carry something out/);
  assert.match(stagedAgents, /never claim you have done something you have\nnot done/);
  assert.equal(fs.readFileSync(path.join(source, 'docs/reference/templates/AGENTS.md'), 'utf8'), upstreamAgents);
  assert.throws(() => stageRuntime(source, output), /exists/i);
});
