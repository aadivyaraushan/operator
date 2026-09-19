import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { promisify } from "node:util";

const run = promisify(execFile);
const script = path.resolve(
  "ios/Runtime/guest/image-build/openclaw-runtime/stage-timing/apply.sh",
);
const pinnedPackage = path.resolve(
  "ios/build/runtime-recovery/r6-official-codex-runtime/extracted/usr/local/lib/node_modules/openclaw",
);
const builtinName = "builtin-openclaw-zQV8Wwjr.js";
const embeddedName = "embedded-agent-DaSvA-Yk.js";

async function copyPinnedFiles() {
  const root = await mkdtemp(path.join(os.tmpdir(), "openclaw-stage-timing-"));
  const packageRoot = path.join(root, "usr/local/lib/node_modules/openclaw");
  const dist = path.join(packageRoot, "dist");
  await mkdir(dist, { recursive: true });
  await writeFile(
    path.join(packageRoot, "package.json"),
    await readFile(path.join(pinnedPackage, "package.json")),
  );
  for (const name of [builtinName, embeddedName]) {
    await writeFile(
      path.join(dist, name),
      await readFile(path.join(pinnedPackage, "dist", name)),
    );
  }
  return { root, dist };
}

test("emits subthreshold startup, prep, and auth stage summaries at info", async () => {
  const { root, dist } = await copyPinnedFiles();
  try {
    await run(script, [root]);
    const builtin = await readFile(path.join(dist, builtinName), "utf8");
    const embedded = await readFile(path.join(dist, embeddedName), "utf8");

    assert.doesNotMatch(
      builtin,
      /if \(!shouldWarn && !options\.log\.isEnabled\("trace"\)\) return;/,
    );
    assert.match(builtin, /else options\.log\.info\(message\);/);
    assert.match(builtin, /else log\$5\.info\(message\);/);
    assert.doesNotMatch(builtin, /!shouldWarn && !log\$5\.isEnabled\("trace"\)/);
    assert.match(embedded, /const authStages = createEmbeddedRunStageTracker\(\);/);
    assert.match(embedded, /label: "auth stages"/);
    assert.match(
      embedded,
      /createEmbeddedRunStageSummaryEmitter\(\{ label: "auth stages", log: log\$3, runId: params\.runId, sessionId: params\.sessionId, tracker: authStages \}\)\("auth"\);/,
    );
    assert.doesNotMatch(embedded, /authStages\?\./);
    assert.doesNotMatch(
      embedded,
      /log\$3\.trace\(formatEmbeddedRunStageSummary\(`\[trace:embedded-run\] auth stages:/,
    );
    await run(process.execPath, ["--check", path.join(dist, builtinName)]);
    await run(process.execPath, ["--check", path.join(dist, embeddedName)]);

    const start = builtin.indexOf("function shouldWarnEmbeddedRunStageSummary");
    const end = builtin.indexOf("//#endregion", start);
    assert.ok(start >= 0 && end > start);
    const loadEmitter = new Function(
      "EMBEDDED_RUN_STAGE_WARN_TOTAL_MS",
      "EMBEDDED_RUN_STAGE_WARN_STAGE_MS",
      `${builtin.slice(start, end)}; return createEmbeddedRunStageSummaryEmitter;`,
    );
    const createEmitter = loadEmitter(10_000, 5_000);
    const calls = [];
    const log = {
      warn: (message) => calls.push(["warn", message]),
      info: (message) => calls.push(["info", message]),
      trace: (message) => calls.push(["trace", message]),
      isEnabled: () => false,
    };
    createEmitter({
      label: "prep stages",
      log,
      runId: "run-1",
      sessionId: "session-1",
      requestBody: "request-body-secret",
      tracker: {
        snapshot: () => ({
          totalMs: 20,
          stages: [{ name: "numeric-stage", durationMs: 20, elapsedMs: 20 }],
          config: "config-secret",
        }),
      },
    })("ready");
    assert.deepEqual(calls.map(([level]) => level), ["info"]);
    assert.match(calls[0][1], /runId=run-1 sessionId=session-1 phase=ready/);
    assert.match(calls[0][1], /totalMs=20 stages=numeric-stage:20ms@20ms/);
    assert.doesNotMatch(calls[0][1], /request-body-secret|config-secret/);

    calls.length = 0;
    createEmitter({
      label: "startup stages",
      log,
      runId: "run-2",
      sessionId: "session-2",
      tracker: {
        snapshot: () => ({
          totalMs: 10_000,
          stages: [{ name: "slow", durationMs: 10_000, elapsedMs: 10_000 }],
        }),
      },
    })("dispatch");
    assert.deepEqual(calls.map(([level]) => level), ["warn"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("is idempotent and fails closed on incompatible source", async () => {
  const { root, dist } = await copyPinnedFiles();
  try {
    await run(script, [root]);
    const firstBuiltin = await readFile(path.join(dist, builtinName), "utf8");
    const firstEmbedded = await readFile(path.join(dist, embeddedName), "utf8");
    await run(script, [root]);
    assert.equal(await readFile(path.join(dist, builtinName), "utf8"), firstBuiltin);
    assert.equal(await readFile(path.join(dist, embeddedName), "utf8"), firstEmbedded);

    await writeFile(path.join(dist, embeddedName), "incompatible source\n");
    const builtinBeforeFailure = await readFile(path.join(dist, builtinName), "utf8");
    await assert.rejects(run(script, [root]), (error) => {
      assert.equal(error.code, 67);
      assert.match(error.stderr, /expected exactly 1/);
      return true;
    });
    assert.equal(
      await readFile(path.join(dist, embeddedName), "utf8"),
      "incompatible source\n",
    );
    assert.equal(await readFile(path.join(dist, builtinName), "utf8"), builtinBeforeFailure);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
