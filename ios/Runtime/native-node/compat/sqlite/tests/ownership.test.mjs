import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';
import { DatabaseSync } from 'node:sqlite';
import { patchNativeOwnershipAdmission } from '../ownership.mjs';

const source = readFileSync(new URL('../../../../../build/runtime-recovery/openclaw-source/package/dist/openclaw-state-db-Bh3Bq87y.js', import.meta.url), 'utf8');
function harness({ cached, status, missing = false, supervised = false, helperError, original = false } = {}) {
  const calls = [];
  const patched = original ? source : patchNativeOwnershipAdmission(source);
  const start = patched.indexOf('async function assertOpenClawStateWriteAllowedAtPath(');
  const end = patched.indexOf('/** Fence shared-state writes', start);
  const context = vm.createContext({
    path: { resolve: value => value }, process: { env: {} },
    existsSync: () => !missing,
    quarantineOrphanedSqliteSidecars: () => calls.push('quarantine'),
    isGatewayExternallySupervised: () => supervised,
    runWithOpenClawStateWriteAccess: () => calls.push('coordinator'),
    prepareSqliteReadOnlyLocation: () => { throw Error('Cannot launch Node CLI inside iOS app'); },
    openClawStateDatabaseCache: { getOpenClawStateDatabaseIfOpenAtPath: () => cached },
    withExistingOpenClawStateDatabaseArtifactPreservingReadOnly: (operation, options) => {
      calls.push(['artifact-preserving-read', options.path]);
      if (helperError) throw helperError;
      return operation({ db: 'existing-or-private-copy' });
    },
    inspectOpenClawStateOwnershipFromDatabase: db => { assert.equal(db, 'existing-or-private-copy'); return status; },
    assertOwnershipAllowsWrite: value => { if (value) throw Error('external ownership'); },
  });
  vm.runInContext(patched.slice(start, end), context);
  return { calls, run: () => context.assertOpenClawStateWriteAllowedAtPath({ databasePath: '/synthetic/state.db' }) };
}

test('existing database ownership uses artifact-preserving helper, not process spawning', async () => {
  await assert.rejects(harness({ original: true }).run(), /Cannot launch Node CLI/);
  const h = harness(); await h.run();
  assert.deepEqual(h.calls, ['quarantine', ['artifact-preserving-read', '/synthetic/state.db']]);
});
test('active cached transaction fails closed before snapshotting or closing files', async () => {
  const h = harness({ cached: { db: { isTransaction: true } } });
  await assert.rejects(h.run(), /active SQLite transaction/);
  assert.deepEqual(h.calls, ['quarantine']);
});
test('external ownership is still rejected', async () => {
  await assert.rejects(harness({ status: { managerId: 'someone' } }).run(), /external ownership/);
});
test('schema, journal, and metadata errors propagate', async () => {
  for (const message of ['newer schema', 'invalid journal', 'invalid ownership']) {
    await assert.rejects(harness({ helperError: Error(message) }).run(), new RegExp(message));
  }
});
test('missing database retains first-start behavior', async () => {
  const h = harness({ missing: true }); await h.run(); assert.deepEqual(h.calls, ['quarantine']);
});
test('supervised recovery retains its existing coordinator', async () => {
  const h = harness({ supervised: true }); await h.run(); assert.deepEqual(h.calls, ['quarantine', 'coordinator']);
});
test('patch is repeatable and rejects source drift', () => {
  const result = patchNativeOwnershipAdmission(source);
  assert.equal(patchNativeOwnershipAdmission(result), result);
  assert.throws(() => patchNativeOwnershipAdmission(source.replace('const prepared = await prepareSqliteReadOnlyLocation(databasePath);', 'const changed = true;')), /expected ownership/);
  assert.match(result, /withExistingOpenClawStateDatabaseArtifactPreservingReadOnly.*from "\.\/openclaw-state-db-readonly/);
});

test('actual upstream helper reuses SQLite connection without closing it and enforces schema version', () => {
  const readonlySource = readFileSync(new URL('../../../../../build/runtime-recovery/openclaw-source/package/dist/openclaw-state-db-readonly-C7txILW9.js', import.meta.url), 'utf8');
  const db = new DatabaseSync(':memory:');
  try {
    db.exec('PRAGMA user_version = 15; CREATE TABLE proof (value INTEGER); INSERT INTO proof VALUES (42)');
    const opened = { db, path: '/synthetic/state.db' };
    const context = vm.createContext({
      path: { resolve: value => value },
      readSqliteUserVersion: database => database.prepare('PRAGMA user_version').get().user_version,
      createNewerSqliteSchemaVersionError: () => Error('newer schema'),
      openClawStateDatabaseCache: {
        getOpenClawStateDatabaseIfOpenAtPath: () => opened,
        evictOpenClawStateDatabaseAfterCorruption: () => {},
      },
      prepareSqliteReadOnlyLocationSync: () => { throw Error('unexpected worker'); },
      prepareSqliteReadOnlyLocationSyncInProcess: () => { throw Error('unexpected source file open'); },
    });
    vm.runInContext(readonlySource.slice(readonlySource.indexOf('function resolveReadOnlyPath'), readonlySource.indexOf('//#endregion')), context);
    const read = () => context.withExistingOpenClawStateDatabaseArtifactPreservingReadOnly(({ db: reused }) => {
      assert.equal(reused, db);
      return reused.prepare('SELECT value FROM proof').get().value;
    }, { path: opened.path });
    assert.equal(read(), 42);
    assert.equal(db.isOpen, true);
    db.exec('PRAGMA user_version = 16');
    assert.throws(read, /newer schema/);
  } finally { db.close(); }
});
