import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

test('production staging composes timing and cache-save patches and is repeatable', () => {
 const scripts = path.resolve('ios/Runtime/guest/image-build/openclaw-runtime');
 const restore = readFileSync(path.join(scripts, 'restore-workspace-templates.sh'), 'utf8');
 const start = restore.indexOf('"$script_dir/stage-timing/apply.sh"');
 const end = restore.indexOf('"$script_dir/stage-npm.sh"', start);
 assert(start >= 0 && end > start);
 const commands = restore.slice(start, end);
 const scratch = mkdtempSync(path.join(os.tmpdir(), 'operator-timing-staging-'));
 const fixture = path.join(scratch, 'usr/local/lib/node_modules/openclaw');
 const baseline = path.resolve('ios/build/runtime-recovery/r6-official-codex-runtime/extracted/usr/local/lib/node_modules/openclaw');
 const builtin = path.join(fixture, 'dist/builtin-openclaw-zQV8Wwjr.js');
 const server = path.join(fixture, 'dist/server-start-BNcm1gUN.js');
 const observer = path.join(fixture, 'dist/attempt.model-diagnostic-events-B4dGIs0S.js');
 try {
  mkdirSync(path.dirname(builtin), { recursive: true });
  writeFileSync(observer, readFileSync(path.join(baseline, 'dist/attempt.model-diagnostic-events-B4dGIs0S.js')));
  for (const file of ['package.json', 'dist/builtin-openclaw-zQV8Wwjr.js', 'dist/embedded-agent-DaSvA-Yk.js', 'dist/server-start-BNcm1gUN.js']) writeFileSync(path.join(fixture, file), readFileSync(path.join(baseline, file)));
  const run = () => execFileSync('/bin/sh', ['-eu', '-c', 'script_dir=$1; staging_root=$2\n' + commands, 'staging-test', scripts, scratch], { env: { PATH: path.dirname(process.execPath) + ':/usr/bin:/bin', TMPDIR: '/private/tmp' } });
  run();
  const changed = readFileSync(builtin, 'utf8');
  assert(changed.includes('params.markStage("bootstrap-files-start")'), 'production staging omitted detailed bootstrap timing');
  assert(changed.includes('else options.log.info(message);'), 'existing numeric summary emission lost');
  assert.equal(statSync(builtin).mode & 0o777, 0o644);
  const cachedServer = readFileSync(server, 'utf8');
  assert.equal(cachedServer.split('flushCompileCache();').length - 1, 1, 'production staging omitted the cache-save checkpoint');
  assert(cachedServer.indexOf('flushCompileCache();') < cachedServer.indexOf('startupTrace.mark("ready");'));
  assert.equal(statSync(server).mode & 0o777, 0o644);
  const timedObserver = readFileSync(observer, 'utf8');
  assert(timedObserver.includes('operator-provider-timing:start'), 'production staging omitted provider timing');
  assert.equal(statSync(observer).mode & 0o777, 0o644);
  run();
  assert.equal(readFileSync(observer, 'utf8'), timedObserver);
  execFileSync(process.execPath, ['--check', observer]);
  assert.equal(readFileSync(builtin, 'utf8'), changed);
  assert.equal(readFileSync(server, 'utf8'), cachedServer);
  execFileSync(process.execPath, ['--check', builtin]);
  execFileSync(process.execPath, ['--check', server]);
 } finally { rmSync(scratch, { recursive: true, force: true }); }
});
