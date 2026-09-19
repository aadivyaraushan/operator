#!/usr/bin/env node
// Disposable, account-free characterization harness. Run only in an owned guest.

import { spawn } from "node:child_process";
import {
  lstat,
  mkdtemp,
  open,
  readdir,
  readFile,
  realpath,
  rm,
} from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import { crc32 } from "node:zlib";

const expectedNode = "v22.23.2";
const cacheDirectory = "/var/tmp/openclaw-compile-cache";
const temporaryRoot = "/var/tmp/openclaw-cache-benchmark-";
const service = "openclaw-gateway";
const tokenPath = "/sys/firmware/qemu_fw_cfg/by_name/opt/openclaw/gateway-token/raw";
const installedModule = "/usr/local/lib/node_modules/openclaw/dist/server-start-BNcm1gUN.js";
const outputLog = "/var/lib/openclaw/.openclaw/logs/stdout.log";
const errorLog = "/var/lib/openclaw/.openclaw/logs/stderr.log";
const startupDeadlineMs = 300_000;
const requestDeadlineMs = 1_500;
const pollIntervalMs = 100;

function fail(code) {
  throw new Error(code);
}

async function requireRegularFile(file, label) {
  const metadata = await lstat(file).catch(() => fail(`${label}_MISSING`));
  if (!metadata.isFile() || metadata.isSymbolicLink()) fail(`${label}_UNSAFE`);
  return metadata;
}

async function requireCacheDirectory() {
  const metadata = await lstat(cacheDirectory).catch(() => fail("CACHE_DIRECTORY_MISSING"));
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) fail("CACHE_DIRECTORY_UNSAFE");
  if (await realpath(cacheDirectory) !== cacheDirectory) fail("CACHE_DIRECTORY_WRONG_TARGET");
}

async function run(command, arguments_, timeoutMs = startupDeadlineMs, allowedExitCodes = [0]) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, arguments_, { stdio: "ignore" });
    let timedOut = false;
    let forceTimer;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      forceTimer = setTimeout(() => child.kill("SIGKILL"), 5_000);
    }, timeoutMs);
    child.once("error", () => {
      clearTimeout(timer);
      clearTimeout(forceTimer);
      reject(new Error("CHILD_LAUNCH_FAILED"));
    });
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      clearTimeout(forceTimer);
      if (timedOut) reject(new Error("CHILD_TIMEOUT"));
      else if (signal === null && allowedExitCodes.includes(code)) resolve(code);
      else reject(new Error("CHILD_EXIT_FAILED"));
    });
  });
}

async function listenerIsOpen() {
  return await new Promise((resolve) => {
    const socket = net.createConnection({ host: "127.0.0.1", port: 18789 });
    const finish = (open) => {
      socket.destroy();
      resolve(open);
    };
    socket.setTimeout(requestDeadlineMs, () => finish(false));
    socket.once("connect", () => finish(true));
    socket.once("error", () => finish(false));
  });
}

async function waitListenerGone() {
  const deadline = performance.now() + 40_000;
  while (performance.now() < deadline) {
    if (!await listenerIsOpen()) return;
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }
  fail("LISTENER_STILL_OPEN");
}

async function stopService() {
  const status = await run("/sbin/rc-service", [service, "status"], 10_000, [0, 3]);
  if (status === 0) await run("/sbin/rc-service", [service, "stop"], 40_000);
  await waitListenerGone();
}

async function forceStopped() {
  try {
    await run("/sbin/rc-service", [service, "stop"], 40_000);
    await waitListenerGone();
  } catch {
    // A cleanup stop is best-effort; the original fixed failure is retained.
  }
}

async function copyTree(source, destination) {
  await run("/bin/cp", ["-a", `${source}/.`, destination]);
}

async function metadataInventory(root) {
  const result = [];
  async function visit(target, relative) {
    const metadata = await lstat(target);
    const type = metadata.isDirectory() ? "d" : metadata.isFile() ? "f" : fail("CACHE_ENTRY_UNSAFE");
    result.push([relative, type, metadata.uid, metadata.gid, metadata.mode & 0o7777]);
    if (type === "d") {
      for (const name of (await readdir(target)).sort()) await visit(path.join(target, name), path.join(relative, name));
    }
  }
  await visit(root, ".");
  return result;
}

async function requireMetadataMatch(left, right) {
  if (JSON.stringify(await metadataInventory(left)) !== JSON.stringify(await metadataInventory(right))) {
    fail("CACHE_METADATA_MISMATCH");
  }
}

async function clearCacheContents() {
  await requireCacheDirectory();
  for (const name of await readdir(cacheDirectory)) {
    await rm(path.join(cacheDirectory, name), { recursive: true, force: false });
  }
}

async function snapshotCache(destination) {
  await requireCacheDirectory();
  await copyTree(cacheDirectory, destination);
  await requireMetadataMatch(cacheDirectory, destination);
}

async function restoreCache(source) {
  await clearCacheContents();
  await copyTree(source, cacheDirectory);
  await requireMetadataMatch(source, cacheDirectory);
}

async function readToken() {
  const raw = await readFile(tokenPath);
  const token = raw.toString("utf8").replaceAll("\0", "");
  if (!token || /\s/u.test(token)) fail("TOKEN_UNAVAILABLE");
  return token;
}

async function readyRequest(token) {
  return await new Promise((resolve) => {
    const request = http.get({
      host: "127.0.0.1",
      port: 18789,
      path: "/ready",
      headers: { authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(requestDeadlineMs),
    }, (response) => {
      const chunks = [];
      let receivedBytes = 0;
      response.on("data", (chunk) => {
        receivedBytes += chunk.length;
        if (receivedBytes > 64 * 1024) request.destroy();
        else chunks.push(chunk);
      });
      response.on("end", () => {
        if (response.statusCode !== 200) return resolve(false);
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")).ready === true);
        } catch {
          resolve(false);
        }
      });
    });
    request.on("error", () => resolve(false));
  });
}

async function logsContain(marker) {
  for (const logPath of [outputLog, errorLog]) {
    const metadata = await lstat(logPath).catch(() => null);
    if (!metadata?.isFile() || metadata.isSymbolicLink() || metadata.size > 16 * 1024 * 1024) continue;
    if ((await readFile(logPath, "utf8")).includes(marker)) return true;
  }
  return false;
}

async function waitUntilReady(token, deadline, { requireFlush = false, sourcePath } = {}) {
  while (performance.now() < deadline) {
    const ready = await readyRequest(token);
    const readyTrace = await logsContain("startup trace: ready");
    const flushed = ready && readyTrace && (!requireFlush || await logsContain("compile-cache-flush-end"));
    const cacheMatched = ready && readyTrace && flushed && (!requireFlush || await hasMatchingCacheHeader(cacheDirectory, sourcePath));
    if (ready && readyTrace && flushed && cacheMatched) return;
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }
  fail("READY_TIMEOUT");
}

async function measuredStartup(token, sourcePath, { requireFlush = false } = {}) {
  const startedAt = performance.now();
  const deadline = startedAt + startupDeadlineMs;
  await run("/sbin/rc-service", [service, "start"], Math.max(1, deadline - performance.now()));
  await waitUntilReady(token, deadline, { requireFlush, sourcePath });
  const elapsedMs = performance.now() - startedAt;
  const matchingBeforeStop = await matchingCacheHeaderCount(cacheDirectory, sourcePath);
  await stopService();
  const matchingAfterStop = await matchingCacheHeaderCount(cacheDirectory, sourcePath);
  return { elapsedMs, matchingBeforeStop, matchingAfterStop };
}

async function listRegularFiles(root) {
  const result = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const child = path.join(directory, entry.name);
      if (entry.isDirectory()) await visit(child);
      else if (entry.isFile()) result.push(child);
      else fail("CACHE_ENTRY_UNSAFE");
    }
  }
  await visit(root);
  return result;
}

async function cacheCount(root) {
  return (await listRegularFiles(root)).length;
}

async function matchingCacheHeaderCount(root, sourcePath) {
  const source = await readFile(sourcePath);
  const expectedSize = source.byteLength;
  const expectedHash = crc32(source) >>> 0;
  let matches = 0;
  for (const cachePath of await listRegularFiles(root)) {
    const handle = await open(cachePath, "r");
    try {
      const header = Buffer.alloc(20);
      const { bytesRead } = await handle.read(header, 0, header.length, 0);
      if (bytesRead !== header.length) continue;
      if (header.readUInt32LE(0) !== 0x8adfdbb2) continue;
      // Node stores cache payload size at byte 8, and the source checksum at byte 12.
      if (header.readUInt32LE(4) === expectedSize && header.readUInt32LE(12) === expectedHash) matches += 1;
    } finally {
      await handle.close();
    }
  }
  return matches;
}

async function hasMatchingCacheHeader(root, sourcePath) {
  return await matchingCacheHeaderCount(root, sourcePath) > 0;
}

async function installPatchedModule(sourcePath) {
  const source = await requireRegularFile(sourcePath, "PATCH_SOURCE");
  const before = await requireRegularFile(installedModule, "INSTALLED_MODULE");
  const contents = await readFile(sourcePath);
  const handle = await open(installedModule, "r+");
  try {
    await handle.writeFile(contents);
    await handle.truncate(contents.length);
    await handle.sync();
  } finally {
    await handle.close();
  }
  const after = await requireRegularFile(installedModule, "INSTALLED_MODULE");
  if (after.ino !== before.ino || after.uid !== before.uid || after.gid !== before.gid || after.mode !== before.mode) {
    fail("PATCH_METADATA_CHANGED");
  }
  if (after.size !== source.size) fail("PATCH_SIZE_MISMATCH");
  if (!(await readFile(installedModule)).equals(await readFile(sourcePath))) fail("PATCH_CONTENT_MISMATCH");
}

async function main() {
  if (process.version !== expectedNode) fail("NODE_VERSION_MISMATCH");
  if (process.getuid?.() !== 0) fail("ROOT_REQUIRED");
  const smoke = process.argv[2] === "--smoke";
  const sourceArgument = smoke ? process.argv[3] : process.argv[2];
  if (!sourceArgument || !path.isAbsolute(sourceArgument) || sourceArgument === "/") fail("PATCH_ARGUMENT_REQUIRED");
  const sourcePath = path.resolve(sourceArgument);
  await requireRegularFile(sourcePath, "PATCH_SOURCE");
  await requireCacheDirectory();
  const token = await readToken();
  const runs = smoke ? 1 : 5;
  const ownedRoot = await mkdtemp(temporaryRoot);
  if (!ownedRoot.startsWith(temporaryRoot)) fail("TEMP_DIRECTORY_UNSAFE");
  const initialCache = path.join(ownedRoot, "initial");
  const candidateCache = path.join(ownedRoot, "candidate");
  await run("/bin/mkdir", ["-m", "0700", initialCache, candidateCache]);

  try {
    await stopService();
    await snapshotCache(initialCache);
    console.log(`INITIAL_CACHE_FILES=${await cacheCount(initialCache)}`);
    for (let index = 1; index <= runs; index += 1) {
      await restoreCache(initialCache);
      console.log(`BASELINE_${index}_MATCHING_BEFORE_START=${await matchingCacheHeaderCount(cacheDirectory, installedModule)}`);
      const result = await measuredStartup(token, installedModule);
      console.log(`BASELINE_${index}_MS=${result.elapsedMs.toFixed(3)}`);
      console.log(`BASELINE_${index}_MATCHING_BEFORE_STOP=${result.matchingBeforeStop}`);
      console.log(`BASELINE_${index}_MATCHING_AFTER_STOP=${result.matchingAfterStop}`);
    }

    await restoreCache(initialCache);
    await installPatchedModule(sourcePath);
    const primer = await measuredStartup(token, installedModule, { requireFlush: true });
    console.log(`PRIMER_MS=${primer.elapsedMs.toFixed(3)}`);
    console.log(`PRIMER_MATCHING_BEFORE_STOP=${primer.matchingBeforeStop}`);
    console.log(`PRIMER_MATCHING_AFTER_STOP=${primer.matchingAfterStop}`);
    await snapshotCache(candidateCache);
    console.log(`CANDIDATE_CACHE_FILES=${await cacheCount(candidateCache)}`);
    if (!await hasMatchingCacheHeader(candidateCache, installedModule)) fail("PATCHED_MODULE_CACHE_MISSING");

    for (let index = 1; index <= runs; index += 1) {
      await restoreCache(candidateCache);
      console.log(`CANDIDATE_${index}_MATCHING_BEFORE_START=${await matchingCacheHeaderCount(cacheDirectory, installedModule)}`);
      const result = await measuredStartup(token, installedModule);
      console.log(`CANDIDATE_${index}_MS=${result.elapsedMs.toFixed(3)}`);
      console.log(`CANDIDATE_${index}_MATCHING_BEFORE_STOP=${result.matchingBeforeStop}`);
      console.log(`CANDIDATE_${index}_MATCHING_AFTER_STOP=${result.matchingAfterStop}`);
    }
    console.log("COMPILE_CACHE_BENCHMARK_PASS");
  } catch (error) {
    await forceStopped();
    console.error(`COMPILE_CACHE_BENCHMARK_FAIL=${error instanceof Error ? error.message : "UNKNOWN"}`);
    process.exitCode = 1;
  } finally {
    await rm(ownedRoot, { recursive: true, force: true });
  }
}

await main();
