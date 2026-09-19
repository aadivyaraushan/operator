import { DatabaseSync } from "node:sqlite";

const [databasePath, expectedVersion] = process.argv.slice(2);
if (!databasePath || !expectedVersion) {
  throw new Error("usage: verify-runtime.mjs DATABASE_PATH EXPECTED_SQLITE_VERSION");
}

const database = new DatabaseSync(databasePath);
try {
  const versionRow = database.prepare("SELECT sqlite_version() AS version").get();
  if (versionRow.version !== expectedVersion) {
    throw new Error(
      `SQLite version mismatch: expected ${expectedVersion}, received ${versionRow.version}`,
    );
  }

  const modeRow = database.prepare("PRAGMA journal_mode=WAL").get();
  const journalMode = Object.values(modeRow)[0];
  if (journalMode !== "wal") {
    throw new Error(`SQLite WAL check failed: received ${journalMode}`);
  }

  database.exec("CREATE TABLE runtime_probe (value TEXT NOT NULL); INSERT INTO runtime_probe VALUES ('ok');");
  const probeRow = database.prepare("SELECT value FROM runtime_probe").get();
  if (probeRow.value !== "ok") {
    throw new Error("SQLite write/read check failed");
  }
} finally {
  database.close();
}
