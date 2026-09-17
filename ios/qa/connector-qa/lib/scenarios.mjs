import { readFileSync, readdirSync } from "node:fs";
import { join, basename } from "node:path";

export const KINDS = ["precise", "casual", "vague", "typo", "indirect", "followup", "clarify", "decline", "write", "handoff"];
export const PROVIDERS = ["google", "microsoft", "slack", "spotify", "notion", "whatsapp", "discord", "canvas", "device", "public"];
const OUTCOMES = ["answer", "clarify", "decline", "handoff"];

export function loadBanks(dir) {
  const banks = [];
  for (const file of readdirSync(dir).filter((f) => f.endsWith(".json")).sort()) {
    const bank = JSON.parse(readFileSync(join(dir, file), "utf8"));
    bank.file = basename(file);
    banks.push(bank);
  }
  const problems = validate(banks);
  if (problems.length) throw new Error("scenario banks invalid:\n" + problems.join("\n"));
  return banks;
}

export function validate(banks) {
  const problems = [];
  const ids = new Map();
  for (const bank of banks) {
    if (!bank.connector) problems.push(`${bank.file}: missing connector`);
    if (!PROVIDERS.includes(bank.provider)) problems.push(`${bank.file}: provider ${bank.provider} not one of ${PROVIDERS.join(",")}`);
    for (const s of bank.scenarios ?? []) {
      const where = `${bank.file}/${s.id}`;
      if (!s.id) problems.push(`${bank.file}: scenario without id`);
      if (ids.has(s.id)) problems.push(`${where}: duplicate id (also in ${ids.get(s.id)})`);
      ids.set(s.id, bank.file);
      if (!KINDS.includes(s.kind)) problems.push(`${where}: kind ${s.kind}`);
      if (!s.prompt?.trim()) problems.push(`${where}: empty prompt`);
      if (!s.expect || !OUTCOMES.includes(s.expect.outcome)) problems.push(`${where}: expect.outcome`);
      if (s.expect?.approval && !["none", "required", "any"].includes(s.expect.approval)) problems.push(`${where}: expect.approval`);
      if (s.approve && !["allow", "deny", "none"].includes(s.approve)) problems.push(`${where}: approve`);
      if (s.launch && !["alternate", "relaunch", "continue"].includes(s.launch)) problems.push(`${where}: launch`);
      if (s.kind === "followup" && !s.after) problems.push(`${where}: followup needs after`);
      if (s.kind === "write" && s.expect?.approval !== "required" && s.approve !== "none") problems.push(`${where}: write needs expect.approval=required`);
    }
  }
  for (const bank of banks) {
    for (const s of bank.scenarios ?? []) {
      if (s.after && !ids.has(s.after)) problems.push(`${bank.file}/${s.id}: after ${s.after} does not exist`);
    }
  }
  return problems;
}

export function allScenarios(banks) {
  const out = [];
  for (const bank of banks) {
    for (const s of bank.scenarios) out.push({ ...s, connector: bank.connector, provider: bank.provider });
  }
  return out;
}

export function select(banks, { connectors = [], scenarioIds = [], kinds = [] } = {}) {
  return allScenarios(banks).filter((s) =>
    (connectors.length === 0 || connectors.includes(s.connector)) &&
    (scenarioIds.length === 0 || scenarioIds.includes(s.id)) &&
    (kinds.length === 0 || kinds.includes(s.kind)));
}

export function fillMarker(prompt, marker) {
  return prompt.replaceAll("{marker}", marker);
}

/// Turns scenarios into the ordered list of driver steps. Repeat 1 relaunches,
/// repeat 2 continues, repeat 3 relaunches, unless the scenario pins `launch`.
/// A scenario with `after` gets its predecessor sent first in the same session.
export function expand(scenarios, banks, { repeats = 3, marker }) {
  const byId = new Map(allScenarios(banks).map((s) => [s.id, s]));
  const steps = [];
  for (const s of scenarios) {
    for (let r = 1; r <= repeats; r += 1) {
      let launch = s.launch && s.launch !== "alternate" ? s.launch : (r % 2 === 1 ? "relaunch" : "continue");
      if (s.after) {
        const pre = byId.get(s.after);
        steps.push(step(pre, r, launch, marker, "pre", `${s.id}#${r}/pre`));
        launch = "continue";
      }
      steps.push(step(s, r, launch, marker, "main", `${s.id}#${r}`));
    }
  }
  return steps;
}

function step(s, repeat, launch, marker, role, stepKey) {
  return {
    stepKey,
    scenarioId: s.id,
    connector: s.connector,
    repeat,
    role,
    prompt: fillMarker(s.prompt, marker),
    launch,
    approve: s.approve ?? "allow",
  };
}

export function newMarker(now = new Date()) {
  const stamp = now.toISOString().replace(/[-:T]/g, "").slice(0, 12);
  const tail = Math.random().toString(16).slice(2, 6);
  return `qa${stamp}${tail}`;
}
