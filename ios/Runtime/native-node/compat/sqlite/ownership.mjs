// Applied only while packaging the pinned native iOS OpenClaw distribution.
// Reuse upstream's journal-aware read path; never run its child-only snapshot
// routines when a cached connection holds an active transaction.
export function patchNativeOwnershipAdmission(source) {
  const marker = '// Operator native ownership admission: preserve cached SQLite locks.';
  if (source.includes(marker)) return source;
  const before = '\tconst prepared = await prepareSqliteReadOnlyLocation(databasePath);\n\ttry {\n\t\tassertOwnershipAllowsWrite(inspectOwnershipThroughConnection(prepared.location, databasePath), databasePath, env);\n\t} finally {\n\t\tprepared.cleanup();\n\t}';
  const after = `\t${marker}
\tconst opened = openClawStateDatabaseCache.getOpenClawStateDatabaseIfOpenAtPath(databasePath);
\tif (opened?.db.isTransaction) throw new Error("[operator-native/sqlite] Cannot inspect ownership during an active SQLite transaction");
\twithExistingOpenClawStateDatabaseArtifactPreservingReadOnly(({ db }) => {
\t\tassertOwnershipAllowsWrite(inspectOpenClawStateOwnershipFromDatabase(db, databasePath), databasePath, env);
\t}, { path: databasePath, env });`;
  const importBefore = 'import { n as withExistingOpenClawStateDatabaseReadOnly } from "./openclaw-state-db-readonly-C7txILW9.js";';
  const importAfter = 'import { n as withExistingOpenClawStateDatabaseReadOnly, t as withExistingOpenClawStateDatabaseArtifactPreservingReadOnly } from "./openclaw-state-db-readonly-C7txILW9.js";';
  if (source.split(before).length !== 2 || source.split(importBefore).length !== 2) {
    throw new Error('[operator-native/sqlite] Pinned OpenClaw source changed: expected ownership admission and readonly import exactly once');
  }
  return source.replace(importBefore, importAfter).replace(before, after);
}
