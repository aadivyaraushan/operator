import assert from "node:assert/strict";
import { mkdtemp, writeFile, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = await mkdtemp(path.join(tmpdir(), "operator-image-byte-test-"));
const cli = path.join(import.meta.dirname, "compare-image-bytes.mjs");

async function runCase(name, before, after, ranges) {
  const caseDir = path.join(root, name);
  await writeFile(caseDir + "-before.raw", before);
  await writeFile(caseDir + "-after.raw", after);
  await writeFile(caseDir + "-ranges.json", typeof ranges === "string" ? ranges : JSON.stringify(ranges));
  return spawnSync(process.execPath, [cli, caseDir + "-before.raw", caseDir + "-after.raw", caseDir + "-ranges.json"], { encoding: "utf8" });
}

const same = Buffer.alloc(131_074, 0x41);
let changed = Buffer.from(same);
changed[65_535] = 0x42;
changed[65_536] = 0x43;
changed[65_537] = 0x44;

let result = await runCase("allowed-crossing", same, changed, [{ start: 65_535, end: 65_538 }]);
assert.equal(result.status, 0, result.stderr);
assert.deepEqual(JSON.parse(result.stdout), { status: "PASS", bytesCompared: 131074, differingBytes: 3, allowedRanges: 1 });
assert.doesNotMatch(result.stdout + result.stderr, /0x4[1234]/);

result = await runCase("outside", same, changed, [{ start: 65_536, end: 65_538 }]);
assert.notEqual(result.status, 0);
assert.deepEqual(JSON.parse(result.stdout), { status: "FAIL", bytesCompared: 131074, differingBytes: 3, disallowedDifferingBytes: 1, allowedRanges: 1 });

result = await runCase("identical", same, same, []);
assert.equal(result.status, 0, result.stderr);
assert.equal(JSON.parse(result.stdout).differingBytes, 0);

for (const [name, ranges] of [
  ["malformed", "{"],
  ["negative", [{ start: -1, end: 1 }]],
  ["reversed", [{ start: 2, end: 1 }]],
  ["empty", [{ start: 1, end: 1 }]],
  ["out-of-bounds", [{ start: 0, end: same.length + 1 }]],
  ["unsafe", [{ start: 0, end: Number.MAX_SAFE_INTEGER + 1 }]],
  ["wrong-shape", { start: 0, end: 1 }],
]) {
  result = await runCase(name, same, same, ranges);
  assert.notEqual(result.status, 0, name);
  assert.equal(JSON.parse(result.stdout).status, "ERROR", name);
}

const shortResult = await runCase("unequal", Buffer.alloc(2), Buffer.alloc(3), []);
assert.notEqual(shortResult.status, 0);
assert.equal(JSON.parse(shortResult.stdout).status, "ERROR");

const symlinkTarget = path.join(root, "regular.raw");
const symlinkPath = path.join(root, "linked.raw");
const rangesPath = path.join(root, "symlink-ranges.json");
await writeFile(symlinkTarget, same);
await symlink(symlinkTarget, symlinkPath);
await writeFile(rangesPath, "[]");
result = spawnSync(process.execPath, [cli, symlinkPath, symlinkTarget, rangesPath], { encoding: "utf8" });
assert.notEqual(result.status, 0);
assert.equal(JSON.parse(result.stdout).status, "ERROR");

console.log("image-byte-preservation tests: PASS (11 cases)");
