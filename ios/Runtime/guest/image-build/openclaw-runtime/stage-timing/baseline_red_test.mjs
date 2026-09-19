import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

const enabled = process.env.OPERATOR_STAGE_TIMING_BASELINE_RED === "1";
const pinnedBuiltin = path.resolve(
  "ios/build/runtime-recovery/r6-official-codex-runtime/extracted/usr/local/lib/node_modules/openclaw/dist/builtin-openclaw-zQV8Wwjr.js",
);

test("pinned emitter reports a subthreshold numeric summary at info", { skip: !enabled }, async () => {
  const source = await readFile(pinnedBuiltin, "utf8");
  const start = source.indexOf("function shouldWarnEmbeddedRunStageSummary");
  const end = source.indexOf("//#endregion", start);
  assert.ok(start >= 0 && end > start, "pinned emitter source is present");
  const loadEmitter = new Function(
    "EMBEDDED_RUN_STAGE_WARN_TOTAL_MS",
    "EMBEDDED_RUN_STAGE_WARN_STAGE_MS",
    `${source.slice(start, end)}; return createEmbeddedRunStageSummaryEmitter;`,
  );
  const createEmitter = loadEmitter(10_000, 5_000);
  const calls = [];
  createEmitter({
    label: "startup stages",
    log: {
      warn: (message) => calls.push(["warn", message]),
      info: (message) => calls.push(["info", message]),
      trace: (message) => calls.push(["trace", message]),
      isEnabled: () => false,
    },
    runId: "run-red",
    sessionId: "session-red",
    tracker: {
      snapshot: () => ({
        totalMs: 20,
        stages: [{ name: "numeric-stage", durationMs: 20, elapsedMs: 20 }],
      }),
    },
  })("ready");
  assert.deepEqual(calls.map(([level]) => level), ["info"]);
});
