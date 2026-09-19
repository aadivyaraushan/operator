#!/usr/bin/env node
import { constants, lstat, open, readFile } from "node:fs/promises";

const CHUNK_BYTES = 64 * 1024;

function print(result) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

async function openRegularReadonly(filePath) {
  const pathStat = await lstat(filePath);
  if (!pathStat.isFile() || pathStat.isSymbolicLink()) throw new Error("invalid input");
  const handle = await open(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  const handleStat = await handle.stat();
  if (!handleStat.isFile() || handleStat.dev !== pathStat.dev || handleStat.ino !== pathStat.ino) {
    await handle.close();
    throw new Error("invalid input");
  }
  return { handle, size: handleStat.size };
}

function parseRanges(value, imageLength) {
  if (!Array.isArray(value)) throw new Error("invalid ranges");
  const ranges = value.map((range) => {
    if (range === null || typeof range !== "object" || Array.isArray(range)) {
      throw new Error("invalid range");
    }
    const keys = Object.keys(range).sort();
    if (keys.length !== 2 || keys[0] !== "end" || keys[1] !== "start") {
      throw new Error("invalid range");
    }
    const { start, end } = range;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)
        || start < 0 || end <= start || end > imageLength) {
      throw new Error("invalid range");
    }
    return { start, end };
  }).sort((a, b) => a.start - b.start || a.end - b.end);

  const merged = [];
  for (const range of ranges) {
    const previous = merged.at(-1);
    if (previous && range.start <= previous.end) previous.end = Math.max(previous.end, range.end);
    else merged.push({ ...range });
  }
  return merged;
}

async function main() {
  const [beforePath, afterPath, rangesPath, extra] = process.argv.slice(2);
  if (!beforePath || !afterPath || !rangesPath || extra) throw new Error("invalid arguments");

  const before = await openRegularReadonly(beforePath);
  let after;
  try {
    after = await openRegularReadonly(afterPath);
    if (before.size !== after.size || !Number.isSafeInteger(before.size)) throw new Error("invalid size");

    const rangesStat = await lstat(rangesPath);
    if (!rangesStat.isFile() || rangesStat.isSymbolicLink()) throw new Error("invalid ranges");
    const ranges = parseRanges(JSON.parse(await readFile(rangesPath, "utf8")), before.size);
    const beforeChunk = Buffer.allocUnsafe(CHUNK_BYTES);
    const afterChunk = Buffer.allocUnsafe(CHUNK_BYTES);
    let differingBytes = 0;
    let disallowedDifferingBytes = 0;
    let rangeIndex = 0;

    for (let offset = 0; offset < before.size; offset += CHUNK_BYTES) {
      const length = Math.min(CHUNK_BYTES, before.size - offset);
      const [beforeRead, afterRead] = await Promise.all([
        before.handle.read(beforeChunk, 0, length, offset),
        after.handle.read(afterChunk, 0, length, offset),
      ]);
      if (beforeRead.bytesRead !== length || afterRead.bytesRead !== length) throw new Error("short read");
      for (let index = 0; index < length; index += 1) {
        if (beforeChunk[index] === afterChunk[index]) continue;
        differingBytes += 1;
        const position = offset + index;
        while (rangeIndex < ranges.length && ranges[rangeIndex].end <= position) rangeIndex += 1;
        if (rangeIndex >= ranges.length
            || position < ranges[rangeIndex].start
            || position >= ranges[rangeIndex].end) {
          disallowedDifferingBytes += 1;
        }
      }
    }

    const common = { bytesCompared: before.size, differingBytes, allowedRanges: ranges.length };
    if (disallowedDifferingBytes > 0) {
      print({ status: "FAIL", ...common, disallowedDifferingBytes });
      process.exitCode = 1;
    } else {
      print({ status: "PASS", ...common });
    }
  } finally {
    await before.handle.close();
    await after?.handle.close();
  }
}

try {
  await main();
} catch {
  print({ status: "ERROR" });
  process.exitCode = 2;
}
