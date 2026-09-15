#!/usr/bin/env node
// Connector QA runner. See SKILL.md for the workflow this belongs to.
//
//   node ios/qa/connector-qa/run.mjs run [--connector a,b] [--scenario id,..] [--kind casual,..]
//        [--repeats 3] [--sim UDID] [--skip-build] [--batch-size 8] [--label name] [--dry-run]
//   node ios/qa/connector-qa/run.mjs report --run <runId>      # merge verdicts.jsonl into report.md
//   node ios/qa/connector-qa/run.mjs cleanup --run <runId>     # sweep the run marker from the owner's accounts
//   node ios/qa/connector-qa/run.mjs list [--connector a]      # print scenarios
//   node ios/qa/connector-qa/run.mjs rescore --run <runId>     # redo mechanical checks from saved files
//
// Every step in `run` is one real model turn on the owner's ChatGPT account.

import { mkdirSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadBanks, select, expand, allScenarios, newMarker } from "./lib/scenarios.mjs";
import { evaluate } from "./lib/checks.mjs";
import { startLogStream, parseLog, window } from "./lib/logs.mjs";
import { DEFAULT_SIM, ensureBooted, appInstalled, conversationPath, readConversation, extractReply } from "./lib/sim.mjs";
import { buildForTesting, xctestrun, runBatch, runCleanup } from "./lib/xcode.mjs";
import { writeJsonl, readJsonl, judgeRows, renderReport, runDir } from "./lib/report.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "../../..");
const SCENARIOS = join(HERE, "scenarios");
const LAUNCH_TIMEOUT = 150;
const REPLY_TIMEOUT = 240;
const CONSECUTIVE_ERRORS_TO_ABORT = 3;

const args = parseArgs(process.argv.slice(2));
const command = args._[0] ?? "run";

try {
  if (command === "run") await runCommand();
  else if (command === "report") reportCommand();
  else if (command === "cleanup") await cleanupCommand();
  else if (command === "list") listCommand();
  else if (command === "rescore") rescoreCommand();
  else throw new Error(`unknown command ${command}`);
} catch (error) {
  console.error(`connector-qa: ${error.message}`);
  process.exit(1);
}

async function runCommand() {
  const banks = loadBanks(SCENARIOS);
  const scenariosById = new Map(allScenarios(banks).map((s) => [s.id, s]));
  const chosen = select(banks, {
    connectors: list(args.connector), scenarioIds: list(args.scenario), kinds: list(args.kind),
  });
  if (chosen.length === 0) throw new Error("no scenarios matched");
  const repeats = Number(args.repeats ?? 3);
  if (repeats < 2 && !args.single) throw new Error("a single repeat hides one-off behaviour; use --repeats 2 or more (or --single for a smoke run)");
  const marker = newMarker();
  const steps = expand(chosen, banks, { repeats, marker });
  const runId = `${new Date().toISOString().replace(/[-:]/g, "").slice(0, 15)}${args.label ? "-" + args.label : ""}`;
  const dir = runDir(REPO, runId);

  console.log(`run ${runId}: ${chosen.length} scenarios, ${steps.length} steps (${steps.length} model turns), marker ${marker}`);
  if (args["dry-run"]) {
    for (const s of steps) console.log(`  ${s.stepKey.padEnd(36)} ${s.launch.padEnd(9)} ${s.approve.padEnd(6)} ${s.prompt}`);
    return;
  }

  mkdirSync(dir, { recursive: true });
  const udid = args.sim ?? process.env.OPERATOR_QA_SIM ?? DEFAULT_SIM;
  const simName = ensureBooted(udid);
  if (!appInstalled(udid)) throw new Error(`Operator is not installed on ${udid}; install the live build first`);
  // A fresh install has no store yet; readConversation treats that as empty.
  writeFileSync(join(dir, "conversation-before.json"), JSON.stringify(readConversation(conversationPath(udid))));

  let testrun = args["skip-build"] ? xctestrun() : null;
  if (!testrun) {
    console.log("building app + QA driver (a few minutes)…");
    testrun = await buildForTesting({ repoRoot: REPO, udid, logFile: join(dir, "build.log") });
  }

  const meta = { runId, marker, udid, simName, startedAt: new Date().toISOString(), repeats, scenarioIds: chosen.map((s) => s.id), account: "ssdear@gmail.com (ChatGPT, personal, owner-approved 2026-09-14)" };
  writeFileSync(join(dir, "run.json"), JSON.stringify(meta, null, 2));

  const logFile = join(dir, "app-log.ndjson");
  const stream = startLogStream(logFile);
  await sleep(2000);

  const results = [];
  const batchSize = Number(args["batch-size"] ?? 8);
  let consecutiveErrors = 0;
  let aborted = null;
  try {
    for (let b = 0; b * batchSize < steps.length; b += 1) {
      const batch = steps.slice(b * batchSize, (b + 1) * batchSize);
      const batchFile = join(dir, `batch-${b}.json`);
      const resultsPath = join(dir, `batch-${b}.results.jsonl`);
      writeFileSync(batchFile, JSON.stringify({
        steps: batch.map((s) => ({ stepKey: s.stepKey, prompt: s.prompt, launch: s.launch, approve: s.approve })),
        resultsPath, launchTimeoutSeconds: LAUNCH_TIMEOUT, replyTimeoutSeconds: REPLY_TIMEOUT,
      }, null, 2));
      console.log(`batch ${b}: ${batch.length} steps`);
      const { code, out } = await runBatch({ udid, batchFile, resultBundle: join(dir, `batch-${b}.xcresult`), logFile: join(dir, `batch-${b}.xcodebuild.log`), testrun });
      const driverRows = readJsonl(resultsPath).length ? readJsonl(resultsPath) : rowsFromStdout(out);
      if (driverRows.length === 0) console.log(`  driver produced no step results (xcodebuild exit ${code}); see batch-${b}.xcodebuild.log`);
      await sleep(3000);
      const logLines = parseLog(logFile);
      // The data container moves when xcodebuild reinstalls the app, so the
      // path is resolved again after every batch.
      const conversation = readConversation(conversationPath(udid));
      // Snapshot what the app had persisted at this moment so a step can be
      // rescored later (run.mjs rescore) without the Simulator.
      writeFileSync(join(dir, `batch-${b}.conversation.json`), JSON.stringify(conversation));
      console.log(`  conversation store: ${conversation.messages?.length ?? 0} messages at ${new Date().toISOString()}`);
      for (const step of batch) {
        const driver = driverRows.find((r) => r.stepKey === step.stepKey) ?? { stepKey: step.stepKey, error: "driver-missing", alerts: [] };
        const record = assemble(step, driver, scenariosById, logLines, conversation);
        results.push(record);
        console.log(`  ${record.stepKey.padEnd(36)} ${record.mechanical.padEnd(7)} ${record.log.commands.join(",") || "-"}  ${(record.reply || record.error || "").slice(0, 70).replace(/\n/g, " ")}`);
        consecutiveErrors = record.error ? consecutiveErrors + 1 : 0;
      }
      writeJsonl(join(dir, "results.jsonl"), results);
      if (consecutiveErrors >= CONSECUTIVE_ERRORS_TO_ABORT) { aborted = `aborted after ${consecutiveErrors} consecutive driver errors`; break; }
    }
  } finally {
    await stream.stop();
  }

  writeJsonl(join(dir, "judge-input.jsonl"), judgeRows(results, scenariosById));
  const report = renderReport({ ...meta, scenarios: chosen, results, verdicts: [], scenariosById, judged: false })
    + (aborted ? `\n\n**${aborted}.**\n` : "");
  writeFileSync(join(dir, "report.md"), report);
  console.log(`\nwrote ${dir}/report.md`);
  if (aborted) console.log(aborted);
  console.log(`next: judge every row in judge-input.jsonl per judge/rubric.md, write verdicts.jsonl, then: node ios/qa/connector-qa/run.mjs report --run ${runId}`);
}

function assemble(step, driver, scenariosById, logLines, conversation) {
  const scenario = scenariosById.get(step.scenarioId);
  const sentAt = driver.sentAt ?? driver.startedAt ?? 0;
  const doneAt = driver.doneAt ?? driver.endedAt ?? (sentAt ? sentAt + REPLY_TIMEOUT : 0);
  const lines = sentAt ? window(logLines, sentAt - 2, doneAt + 3) : [];
  const reply = sentAt ? extractReply(conversation, step.prompt, sentAt) : { text: "", ids: [] };
  const { checks, mechanical, log } = evaluate(scenario, { ...step, ...driver }, reply.text, lines);
  return {
    stepKey: step.stepKey, scenarioId: step.scenarioId, connector: step.connector, role: step.role, repeat: step.repeat,
    launch: step.launch, approve: step.approve, prompt: step.prompt, reply: reply.text, replyMessageIds: reply.ids,
    sentAt, doneAt: driver.doneAt ?? null, elapsedSeconds: driver.doneAt && sentAt ? Math.round(driver.doneAt - sentAt) : null,
    alerts: driver.alerts ?? [], error: driver.error ?? null, sawWorking: driver.sawWorking ?? false,
    log: { commands: log.commands, operations: log.operations, responses: log.responses, rejected: log.rejected, blockedHits: log.blockedHits, denied: log.denied },
    logLines: lines.map((l) => `${l.category}: ${l.message}`),
    checks, mechanical,
  };
}

function rowsFromStdout(out) {
  const rows = [];
  for (const line of out.split("\n")) {
    const i = line.indexOf("QA-STEP ");
    if (i >= 0) { try { rows.push(JSON.parse(line.slice(i + 8))); } catch { /* partial line */ } }
  }
  return rows;
}

function reportCommand() {
  const runId = need("run");
  const dir = runDir(REPO, runId);
  const meta = JSON.parse(readFileSync(join(dir, "run.json"), "utf8"));
  const banks = loadBanks(SCENARIOS);
  const scenariosById = new Map(allScenarios(banks).map((s) => [s.id, s]));
  const results = readJsonl(join(dir, "results.jsonl"));
  const verdicts = readJsonl(join(dir, "verdicts.jsonl"));
  if (verdicts.length === 0) throw new Error(`${dir}/verdicts.jsonl is missing or empty; judge first`);
  const missing = results.filter((r) => !verdicts.some((v) => v.stepKey === r.stepKey)).map((r) => r.stepKey);
  if (missing.length) throw new Error(`no verdict for: ${missing.join(", ")}`);
  const bad = verdicts.filter((v) => !["pass", "fail"].includes(v.verdict) || !v.reason);
  if (bad.length) throw new Error(`verdicts need verdict pass|fail and a reason: ${bad.map((v) => v.stepKey).join(", ")}`);
  writeFileSync(join(dir, "report.md"), renderReport({ ...meta, scenarios: [], results, verdicts, scenariosById, judged: true }));
  console.log(`wrote ${dir}/report.md`);
}

async function cleanupCommand() {
  const runId = need("run");
  const dir = runDir(REPO, runId);
  const meta = JSON.parse(readFileSync(join(dir, "run.json"), "utf8"));
  ensureBooted(meta.udid);
  console.log(`sweeping marker ${meta.marker} from the owner's accounts…`);
  const { code, out } = await runCleanup({ repoRoot: REPO, udid: meta.udid, marker: meta.marker, logFile: join(dir, "cleanup.xcodebuild.log") });
  const summary = out.split("\n").filter((l) => /LIVE-CLEANUP|Executed|error:|skipped/.test(l));
  // A skipped cleanup test (provider not connected) swept nothing. If this run
  // wrote to that provider, say so loudly instead of reporting a clean sweep.
  const results = readJsonl(join(dir, "results.jsonl"));
  const written = new Set(results.flatMap((r) => r.log.operations).filter((o) => /Create|Send|Post/.test(o)));
  const skipped = summary.filter((l) => /skipped/.test(l)).map((l) => (l.match(/testCleanup(\w+)/) ?? [])[1]).filter(Boolean);
  const unswept = [...written].filter((op) => skipped.some((name) => op.toLowerCase().startsWith(name.replace(/AndCalendar|DraftsAndSent|SelfDM/, "").toLowerCase().slice(0, 6))));
  writeFileSync(join(dir, "cleanup.txt"), summary.join("\n") + `\nwrites=${[...written].join(",") || "none"}\nskipped=${skipped.join(",") || "none"}\nunswept=${unswept.join(",") || "none"}\nexit=${code}\n`);
  console.log(summary.join("\n"));
  console.log(`writes in this run: ${[...written].join(", ") || "none"}; cleanup tests skipped: ${skipped.join(", ") || "none"}`);
  if (code !== 0) throw new Error(`cleanup exited ${code}; see ${dir}/cleanup.xcodebuild.log`);
  if (unswept.length) throw new Error(`NOT swept (cleanup test skipped): ${unswept.join(", ")}; reconnect the provider and rerun cleanup`);
  console.log("Notion pages are not swept (no delete tool): remove any 'Operator QA' pages by hand.");
}

/// Re-runs the mechanical checks for a saved run from its own files: the
/// driver rows, the app log and the per-batch conversation snapshots. Use it
/// after changing lib/checks.mjs or a scenario's expect block.
function rescoreCommand() {
  const runId = need("run");
  const dir = runDir(REPO, runId);
  const meta = JSON.parse(readFileSync(join(dir, "run.json"), "utf8"));
  const banks = loadBanks(SCENARIOS);
  const scenariosById = new Map(allScenarios(banks).map((s) => [s.id, s]));
  const old = readJsonl(join(dir, "results.jsonl"));
  const logLines = parseLog(join(dir, "app-log.ndjson"));
  const results = [];
  for (let b = 0; existsSync(join(dir, `batch-${b}.json`)); b += 1) {
    const batch = JSON.parse(readFileSync(join(dir, `batch-${b}.json`), "utf8"));
    const driverRows = readJsonl(join(dir, `batch-${b}.results.jsonl`));
    const snapshot = join(dir, `batch-${b}.conversation.json`);
    let conversation = existsSync(snapshot) ? JSON.parse(readFileSync(snapshot, "utf8")) : { messages: [] };
    if (!conversation.messages?.length) conversation = readConversation(conversationPath(meta.udid));
    for (const s of batch.steps) {
      const prev = old.find((r) => r.stepKey === s.stepKey);
      if (!prev) continue;
      const step = { stepKey: s.stepKey, scenarioId: prev.scenarioId, connector: prev.connector, role: prev.role, repeat: prev.repeat, prompt: s.prompt, launch: s.launch, approve: s.approve };
      const driver = driverRows.find((r) => r.stepKey === s.stepKey) ?? { stepKey: s.stepKey, error: "driver-missing", alerts: [] };
      const record = assemble(step, driver, scenariosById, logLines, conversation);
      results.push(record);
      console.log(`  ${record.stepKey.padEnd(36)} ${record.mechanical.padEnd(7)} ${record.log.commands.join(",") || "-"}  ${(record.reply || record.error || "").slice(0, 70).replace(/\n/g, " ")}`);
    }
  }
  writeJsonl(join(dir, "results.jsonl"), results);
  writeJsonl(join(dir, "judge-input.jsonl"), judgeRows(results, scenariosById));
  writeFileSync(join(dir, "report.md"), renderReport({ ...meta, scenarios: [], results, verdicts: [], scenariosById, judged: false }));
  console.log(`rescored ${results.length} steps; wrote ${dir}/report.md`);
}

function listCommand() {
  const banks = loadBanks(SCENARIOS);
  for (const s of select(banks, { connectors: list(args.connector), kinds: list(args.kind) })) {
    console.log(`${s.connector.padEnd(16)} ${s.kind.padEnd(9)} ${s.id.padEnd(28)} ${s.prompt}`);
  }
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) out[key] = true;
      else { out[key] = next; i += 1; }
    } else out._.push(a);
  }
  return out;
}
function list(v) { return v ? String(v).split(",").map((s) => s.trim()).filter(Boolean) : []; }
function need(key) { if (!args[key]) throw new Error(`--${key} is required`); return args[key]; }
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
