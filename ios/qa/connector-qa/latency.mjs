#!/usr/bin/env node
// Where a turn's seconds go, from saved app logs.
//   node ios/qa/connector-qa/latency.mjs [app-log.ndjson ...]
// With no arguments, every saved-results/connector-qa/runs/*/app-log.ndjson.
import { readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { parseLog } from "./lib/logs.mjs";
import { budget, formatTable, summarize, turnsFrom } from "./lib/latency.mjs";

const runsDir = "saved-results/connector-qa/runs";
const files = process.argv.slice(2).length
  ? process.argv.slice(2)
  : readdirSync(runsDir).map((d) => join(runsDir, d, "app-log.ndjson")).filter(existsSync).sort();

const rows = [];
for (const file of files) {
  for (const turn of turnsFrom(parseLog(file))) {
    if (turn.accepted === undefined) continue;
    const at = new Date(turn.accepted * 1000).toISOString().slice(11, 19);
    rows.push({ at, run: file.split("/").at(-2), ...budget(turn) });
  }
}
console.log(formatTable(rows));
const s = summarize(rows);
console.log(`
turns=${s.turns} median total=${s.medianTotal}s median to-first-text=${s.medianToFirstText}s tool share=${s.toolShare}%
with tools (${s.withTools.turns}): median accepted->first tool call=${s.withTools.medianFirstDecision}s, median round trips=${s.withTools.medianRoundTrips}, median total=${s.withTools.medianTotal}s
no tools (${s.withoutTools.turns}): median total=${s.withoutTools.medianTotal}s`);
