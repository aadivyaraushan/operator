import assert from 'node:assert/strict';
import { readFile, readdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

async function guestConfig() {
  const source = await readFile(new URL('../../guest/first-boot/provision-guest.sh', import.meta.url), 'utf8');
  const match = source.match(/printf '%s\\n' '(\{"gateway":.*\})'/);
  assert.ok(match, 'guest configuration must be inspected, not a separate test fixture');
  return JSON.parse(match[1]);
}

test('guest commands use local execution with approval and no elevated bypass', async () => {
  const config = await guestConfig();
  assert.deepEqual(config.tools?.exec, { host: 'gateway', mode: 'ask' });
  assert.equal(config.tools?.elevated?.enabled, false);
});

const packageRoot = process.env.OPERATOR_TEST_OPENCLAW_PACKAGE;
test('packaged CLI accepts the exact provisioned configuration',
  { skip: !packageRoot, timeout: 20000 }, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'operator-config-check-'));
    try {
      const configPath = join(directory, 'openclaw.json');
      await writeFile(configPath, JSON.stringify(await guestConfig()), { mode: 0o600 });
      const { stdout } = await promisify(execFile)(process.execPath,
        [join(packageRoot, 'openclaw.mjs'), 'config', 'validate', '--json'],
        { timeout: 15000, env: { ...process.env, OPENCLAW_CONFIG_PATH: configPath,
          OPENCLAW_STATE_DIR: join(directory, 'state') } });
      assert.equal(JSON.parse(stdout).valid, true);
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

test('packaged policy requires approval for a previously unapproved command',
  { skip: !packageRoot }, async () => {
    const config = await guestConfig();
    const dist = join(packageRoot, 'dist');
    let api;
    for (const name of await readdir(dist)) {
      if (!/^exec-approvals-[A-Za-z0-9_]+\.js$/.test(name)) continue;
      const candidate = await import(pathToFileURL(join(dist, name)).href);
      if (candidate.resolveExecModePolicy && candidate.requiresExecApproval) { api = candidate; break; }
    }
    assert.ok(api, 'pinned upstream policy exports must exist');
    const policy = api.resolveExecModePolicy({ mode: config.tools?.exec?.mode, security: 'full', ask: 'off' });
    assert.equal(policy.autoReview, false);
    assert.equal(api.requiresExecApproval({ ...policy, analysisOk: true, allowlistSatisfied: false }), true);
    assert.equal(api.requiresExecApproval({ ...policy, analysisOk: false, allowlistSatisfied: false }), true);
    assert.equal(api.DEFAULT_EXEC_APPROVAL_ASK_FALLBACK, 'deny');
  });
