import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseLog, parseTimestamp, window } from "../lib/logs.mjs";
import { extractReply } from "../lib/sim.mjs";

test("parseTimestamp handles the unified log format with zone", () => {
  const t = parseTimestamp("2026-09-14 19:42:01.123456-0500");
  assert.equal(new Date(t * 1000).toISOString(), "2026-09-15T00:42:01.123Z");
});

test("parseLog keeps only well-formed ndjson lines with a message", () => {
  const dir = mkdtempSync(join(tmpdir(), "qa-"));
  const file = join(dir, "log.ndjson");
  writeFileSync(file, [
    'Filtering the log data using "subsystem == \\"app.operator.ios\\""',
    JSON.stringify({ timestamp: "2026-09-14 19:42:01.000000-0500", category: "location-node", eventMessage: "[location-node] handling command=connections.read id=1" }),
    "{not json",
    JSON.stringify({ timestamp: "2026-09-14 19:42:02.000000-0500", category: "chat" }),
  ].join("\n"));
  const lines = parseLog(file);
  assert.equal(lines.length, 1);
  assert.equal(lines[0].category, "location-node");
  assert.deepEqual(window(lines, lines[0].t - 1, lines[0].t + 1).length, 1);
  assert.deepEqual(window(lines, lines[0].t + 5, lines[0].t + 9).length, 0);
});

const APPLE = 978307200;
test("extractReply finds the assistant messages that answered the prompt", () => {
  const now = 1_800_000_000;
  const conv = { messages: [
    { role: "user", text: "old", createdAt: now - 5000 - APPLE },
    { role: "assistant", text: "old reply", createdAt: now - 4990 - APPLE },
    { role: "user", text: "anything new in my inbox?", createdAt: now + 1 - APPLE },
    { role: "assistant", text: "Two new emails.", createdAt: now + 20 - APPLE, id: "r1" },
    { role: "assistant", text: "Want details?", createdAt: now + 21 - APPLE, id: "r2" },
    { role: "user", text: "yes", createdAt: now + 60 - APPLE },
  ] };
  const r = extractReply(conv, "anything new in my inbox?", now);
  assert.equal(r.text, "Two new emails.\n\nWant details?");
  assert.deepEqual(r.ids, ["r1", "r2"]);
});

test("extractReply ignores an older identical prompt from a previous run", () => {
  const now = 1_800_000_000;
  const conv = { messages: [
    { role: "user", text: "battery?", createdAt: now - 9000 - APPLE },
    { role: "assistant", text: "stale", createdAt: now - 8990 - APPLE },
  ] };
  assert.equal(extractReply(conv, "battery?", now).text, "");
});

test("extractReply takes the first identical prompt sent after sentAt, not a later repeat", () => {
  const now = 1_800_000_000;
  const conv = { messages: [
    { role: "user", text: "battery?", createdAt: now + 1 - APPLE },
    { role: "assistant", text: "first", createdAt: now + 10 - APPLE, id: "a" },
    { role: "user", text: "battery?", createdAt: now + 100 - APPLE },
    { role: "assistant", text: "second", createdAt: now + 110 - APPLE, id: "b" },
  ] };
  assert.equal(extractReply(conv, "battery?", now).text, "first");
  assert.equal(extractReply(conv, "battery?", now + 99).text, "second");
});
