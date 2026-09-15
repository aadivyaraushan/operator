import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { aggregate } from "./checks.mjs";

export function writeJsonl(file, rows) {
  writeFileSync(file, rows.map((r) => JSON.stringify(r)).join("\n") + (rows.length ? "\n" : ""));
}

export function readJsonl(file) {
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8").split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}

/// One row per step, for the judge. Carries everything the rubric needs and
/// the mechanical verdict so the judge never overrides a mechanical fail.
export function judgeRows(results, scenariosById) {
  return results.map((r) => {
    const s = scenariosById.get(r.scenarioId);
    return {
      stepKey: r.stepKey, scenarioId: r.scenarioId, connector: r.connector, kind: s?.kind, role: r.role,
      repeat: r.repeat, launch: r.launch, prompt: r.prompt, reply: r.reply,
      expect: s?.expect, mechanical: r.mechanical,
      failedChecks: r.checks.filter((c) => !c.pass).map((c) => `${c.name}: ${c.detail}`),
      commands: r.log.commands, operations: r.log.operations, responses: r.log.responses,
      alerts: r.alerts, elapsedSeconds: r.elapsedSeconds, driverError: r.error ?? null,
    };
  });
}

/// Scenario verdicts from step results plus optional judge verdicts
/// ({stepKey, verdict: pass|fail, reason}). A judge may turn a mechanical pass
/// into a fail, never the reverse.
export function scenarioVerdicts(results, verdicts = []) {
  const byStep = new Map(verdicts.map((v) => [v.stepKey, v]));
  const byScenario = new Map();
  for (const r of results) {
    if (r.role !== "main") continue;
    const judge = byStep.get(r.stepKey);
    let final = r.mechanical;
    if (final === "pass" && judge?.verdict === "fail") final = "fail";
    const list = byScenario.get(r.scenarioId) ?? [];
    list.push({ ...r, judge, final });
    byScenario.set(r.scenarioId, list);
  }
  const out = [];
  for (const [scenarioId, steps] of byScenario) {
    out.push({ scenarioId, connector: steps[0].connector, verdict: aggregate(steps.map((s) => s.final)), steps });
  }
  return out;
}

export function renderReport({ runId, marker, udid, startedAt, scenarios, results, verdicts, scenariosById, judged }) {
  const rows = scenarioVerdicts(results, verdicts);
  const byConnector = new Map();
  for (const row of rows) {
    const list = byConnector.get(row.connector) ?? [];
    list.push(row);
    byConnector.set(row.connector, list);
  }
  const counts = { pass: 0, flaky: 0, fail: 0, blocked: 0 };
  for (const row of rows) counts[row.verdict] += 1;
  const turns = results.length;
  const lines = [];
  lines.push(`# Connector QA run ${runId}`);
  lines.push("");
  lines.push(`Started ${startedAt}. Simulator \`${udid}\`. Run marker \`${marker}\` (sweep with \`node ios/qa/connector-qa/run.mjs cleanup --run ${runId}\`).`);
  lines.push(`Model turns spent: ${turns} on ssdear@gmail.com (ChatGPT, personal, owner-approved 2026-09-14).`);
  lines.push(judged ? "Judge verdicts applied." : "**Mechanical verdicts only. The judge has not run yet** (see SKILL.md step 5).");
  lines.push("");
  lines.push(`| verdict | scenarios |\n|---|---|\n| pass | ${counts.pass} |\n| flaky | ${counts.flaky} |\n| fail | ${counts.fail} |\n| blocked | ${counts.blocked} |`);
  lines.push("");
  for (const [connector, list] of [...byConnector].sort()) {
    lines.push(`## ${connector}`);
    lines.push("");
    lines.push("| scenario | kind | verdict | repeats | why |");
    lines.push("|---|---|---|---|---|");
    for (const row of list) {
      const s = scenariosById.get(row.scenarioId);
      const repeats = row.steps.map((st) => `${st.repeat}:${st.final[0]}`).join(" ");
      const why = row.steps.filter((st) => st.final !== "pass").map((st) => {
        const failed = st.checks.filter((c) => !c.pass).map((c) => `${c.name} (${c.detail})`);
        const judge = st.judge?.verdict === "fail" ? `judge: ${st.judge.reason}` : "";
        return [`#${st.repeat}`, ...failed, judge].filter(Boolean).join("; ");
      }).join("<br>");
      lines.push(`| ${row.scenarioId} | ${s?.kind ?? ""} | **${row.verdict}** | ${repeats} | ${escape(why)} |`);
    }
    lines.push("");
  }
  lines.push("## Every turn");
  lines.push("");
  for (const r of results) {
    lines.push(`### ${r.stepKey} (${r.launch}, ${r.elapsedSeconds ?? "?"} s, ${r.mechanical})`);
    lines.push("");
    lines.push(`Prompt: ${r.prompt}`);
    lines.push("");
    lines.push(`Commands: ${r.log.commands.join(", ") || "none"}. Operations: ${r.log.operations.join(", ") || "none"}. Responses: ${r.log.responses.map((x) => `${x.operation}=${x.status}`).join(", ") || "none"}. Alerts: ${r.alerts.map((a) => `${a.title} → ${a.action}`).join("; ") || "none"}.`);
    lines.push("");
    lines.push("Reply:");
    lines.push("");
    lines.push("```");
    lines.push(r.reply || `(none; ${r.error ?? "no reply"})`);
    lines.push("```");
    lines.push("");
  }
  return lines.join("\n");
}

function escape(s) { return String(s).replaceAll("|", "\\|").replaceAll("\n", " "); }

export function runDir(repoRoot, runId) {
  return join(repoRoot, "saved-results", "connector-qa", "runs", runId);
}
