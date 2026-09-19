import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { enableCompileCache, flushCompileCache } from "node:module";

const expected = Array.from({ length: 200 }, (_, index) => (17 + index) * (index + 3))
  .reduce((sum, item) => sum + item, 0);

async function cacheStats(path) {
  let files = 0;
  let bytes = 0;
  for (const entry of await readdir(path, { withFileTypes: true }).catch(() => [])) {
    const childPath = join(path, entry.name);
    if (entry.isDirectory()) {
      const child = await cacheStats(childPath);
      files += child.files;
      bytes += child.bytes;
    } else if (entry.isFile()) {
      files += 1;
      bytes += (await stat(childPath)).size;
    }
  }
  return { files, bytes };
}

if (process.argv[2] === "--child") {
  const mode = process.argv[3];
  const cacheDir = process.argv[4];
  const enabled = enableCompileCache(cacheDir);
  assert.ok(enabled.directory, "compile cache did not enable");
  const { syntheticResult } = await import("./fixture.mjs");
  assert.equal(syntheticResult(17), expected);
  if (mode === "flush" || mode === "flush-hold") flushCompileCache();
  process.stdout.write(`${JSON.stringify({ ready: true, beforeExit: await cacheStats(cacheDir), result: expected })}\n`);
  if (mode === "hold" || mode === "flush-hold") {
    await new Promise(resolve => {
      const liveHandle = setInterval(() => {}, 1_000);
      process.once("SIGTERM", () => {
        clearInterval(liveHandle);
        resolve();
      });
    });
  }
  process.exitCode = 0;
} else {
  const node = process.execPath;
  const root = await mkdtemp(join(tmpdir(), "operator-compile-cache-"));
  const children = new Set();
  const run = (mode, cacheDir) => new Promise((resolve, reject) => {
    const child = spawn(node, [fileURLToPath(import.meta.url), "--child", mode, cacheDir], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.add(child);
    let stdout = "";
    let stderr = "";
    let observation;
    let timedOut = false;
    const deadline = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, 5_000);
    child.stdout.on("data", chunk => {
      stdout += chunk;
      if ((mode === "hold" || mode === "flush-hold") && !observation && stdout.includes("\n")) {
        observation = JSON.parse(stdout.trim());
        child.kill("SIGKILL");
      }
    });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      clearTimeout(deadline);
      children.delete(child);
      if (timedOut) {
        reject(new Error(`child ${mode} exceeded 5000ms`));
      } else if ((mode === "hold" || mode === "flush-hold") && signal === "SIGKILL" && observation) {
        resolve({ child, observation, code, signal });
      } else if (code !== 0) {
        reject(new Error(`child ${mode} failed code=${code} signal=${signal} stderr=${stderr.trim()}`));
      } else {
        resolve({ child, observation: JSON.parse(stdout.trim()), code, signal });
      }
    });
  });

  try {
    const normalDir = join(root, "normal");
    const flushDir = join(root, "flush");
    const killedDir = join(root, "killed");
    const normal = await run("normal", normalDir);
    const normalAfterExit = await cacheStats(normalDir);
    const normalReload = await run("normal", normalDir);
    const flushed = await run("flush", flushDir);
    const flushAfterExit = await cacheStats(flushDir);
    const killed = await run("hold", killedDir);
    const killedAfterExit = await cacheStats(killedDir);
    const killedReload = await run("normal", killedDir);
    const flushKilledDir = join(root, "flush-killed");
    const flushKilled = await run("flush-hold", flushKilledDir);
    const flushKilledAfterExit = await cacheStats(flushKilledDir);
    const flushKilledReload = await run("normal", flushKilledDir);

    assert.equal(normal.observation.result, expected);
    assert.equal(normalReload.observation.result, expected);
    assert.equal(killedReload.observation.result, expected);
    assert.equal(flushKilledReload.observation.result, expected);
    assert.deepEqual(normal.observation.beforeExit, { files: 0, bytes: 0 });
    assert.ok(normalAfterExit.files > 0 && normalAfterExit.bytes > 0);
    assert.ok(flushed.observation.beforeExit.files > 0);
    assert.ok(flushAfterExit.files >= flushed.observation.beforeExit.files);
    assert.equal(killed.signal, "SIGKILL");
    assert.deepEqual(killedAfterExit, killed.observation.beforeExit);
    assert.deepEqual(killedAfterExit, { files: 0, bytes: 0 });
    assert.equal(flushKilled.signal, "SIGKILL");
    assert.ok(flushKilled.observation.beforeExit.files > 0 && flushKilled.observation.beforeExit.bytes > 0);
    assert.deepEqual(flushKilledAfterExit, flushKilled.observation.beforeExit);

    process.stdout.write(`${JSON.stringify({
      status: "PASS",
      node: process.version,
      normal: { beforeExit: normal.observation.beforeExit, afterExit: normalAfterExit },
      flush: { beforeExit: flushed.observation.beforeExit, afterExit: flushAfterExit },
      sigkill: { beforeKill: killed.observation.beforeExit, afterKill: killedAfterExit },
      flushThenSigkill: { beforeKill: flushKilled.observation.beforeExit, afterKill: flushKilledAfterExit },
      reloadsCorrect: true,
      remainingChildren: children.size,
    })}\n`);
  } finally {
    await Promise.all(Array.from(children, child => new Promise(resolve => {
      if (child.exitCode !== null || child.signalCode !== null) return resolve();
      child.once("exit", resolve);
      child.kill("SIGKILL");
    })));
    await rm(root, { recursive: true, force: true });
  }
}
