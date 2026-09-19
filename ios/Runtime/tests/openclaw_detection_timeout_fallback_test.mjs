import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";

const run = promisify(execFile);
const script = path.resolve(
  "ios/Runtime/guest/image-build/openclaw-runtime/patch-detection-timeout-fallback.sh",
);
const pinnedPackage = path.resolve("ios/build/runtime-recovery/openclaw-source/package");

async function fixtureRoot() {
  const root = await mkdtemp(path.join(os.tmpdir(), "openclaw-detection-"));
  const packageRoot = path.join(root, "usr/local/lib/node_modules/openclaw");
  const file = path.join(packageRoot, "dist/setup-inference-detection-BPPYzRNV.js");
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(path.join(packageRoot, "package.json"), '{"version":"2026.9.1"}\n');
  await writeFile(file, "if (detection.candidates.length > 0 || detection.unavailableCandidates.length > 0) {");
  return { root, file };
}

test("patches the pinned timeout fallback and preserves partial setup options", async () => {
  const { root, file } = await fixtureRoot();
  try {
    await run(script, [root]);
    const patched = await readFile(file, "utf8");
    assert.match(patched, /authOptions\?\.length/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("actual pinned detector returns auth-only partials on timeout but rejects empty partials", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "openclaw-detection-real-"));
  const runtimePackage = path.join(root, "usr/local/lib/node_modules/openclaw");
  await mkdir(path.dirname(runtimePackage), { recursive: true });
  await mkdir(path.join(runtimePackage, "dist"), { recursive: true });
  await writeFile(
    path.join(runtimePackage, "package.json"),
    await readFile(path.join(pinnedPackage, "package.json")),
  );
  await writeFile(
    path.join(runtimePackage, "dist/setup-inference-detection-BPPYzRNV.js"),
    await readFile(path.join(pinnedPackage, "dist/setup-inference-detection-BPPYzRNV.js")),
  );
  const worker = path.join(root, "partial-worker.mjs");
  await writeFile(
    worker,
    `import { parentPort, workerData } from "node:worker_threads";
parentPort.postMessage({ type: "partial", detection: workerData.detection });
setInterval(() => {}, 1000);
`,
  );
  try {
    await run(script, [root]);
    const source = await readFile(
      path.join(runtimePackage, "dist/setup-inference-detection-BPPYzRNV.js"),
      "utf8",
    );
    const body = source.slice(source.indexOf("const SETUP_INFERENCE_DETECTION_TIMEOUT_MS"));
    const detector = path.join(root, "detector.mjs");
    await writeFile(
      detector,
      `import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { Worker } from "node:worker_threads";
const createSubsystemLogger = () => ({ warn() {} });
const DEFAULT_AGENT_WORKSPACE_DIR = "/tmp/workspace";
const listRecommendedToolInstalls = () => [];
const resolveSetupInferenceCandidateBrandId = () => undefined;
const detectAmbientInferenceBackends = () => [];
${body}`,
    );
    const module = await import(`${pathToFileURL(detector).href}?test=${Date.now()}`);
    const workerURL = pathToFileURL(worker);
    async function timedOutPartial(detection) {
      return module.detectSetupInferenceIsolated({
        workerUrl: workerURL,
        timeoutMs: 200,
        workerData: { detection },
      });
    }
    const authOnly = await timedOutPartial({
      candidates: [],
      unavailableCandidates: [],
      manualProviders: [],
      authOptions: [{ id: "openai-device-code", kind: "device-code" }],
    });
    assert.equal(authOnly.authOptions[0].id, "openai-device-code");
    const manualOnly = await timedOutPartial({
      candidates: [],
      unavailableCandidates: [],
      manualProviders: [{ id: "openai-api-key" }],
      authOptions: [],
    });
    assert.equal(manualOnly.manualProviders[0].id, "openai-api-key");
    const candidateOnly = await timedOutPartial({
      candidates: [{ kind: "existing-model", modelRef: "openai/gpt-5" }],
      unavailableCandidates: [],
      authOptions: [],
    });
    assert.equal(candidateOnly.candidates[0].modelRef, "openai/gpt-5");
    await assert.rejects(
      module.detectSetupInferenceIsolated({
        workerUrl: workerURL,
        timeoutMs: 200,
        workerData: {
          detection: { candidates: [], unavailableCandidates: [], authOptions: [] },
        },
      }),
      /did not finish after/,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
