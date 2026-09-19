import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { loadBanks, allScenarios, select, expand, validate, KINDS, newMarker } from "../lib/scenarios.mjs";

const DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "scenarios");

test("every bank loads, ids are unique, and every followup has a real predecessor", () => {
  const banks = loadBanks(DIR);
  assert.ok(banks.length >= 20);
  assert.equal(validate(banks).length, 0);
});

test("every bank covers the required kinds", () => {
  const required = ["precise", "casual", "vague", "typo", "indirect", "followup", "clarify"];
  for (const bank of loadBanks(DIR)) {
    const kinds = new Set(bank.scenarios.map((s) => s.kind));
    for (const k of required) assert.ok(kinds.has(k), `${bank.connector} lacks a ${k} scenario`);
  }
});

test("write prompts carry the marker and only target the owner", () => {
  for (const s of allScenarios(loadBanks(DIR)).filter((s) => s.kind === "write")) {
    assert.ok(s.prompt.includes("{marker}") || s.approve === "deny" || s.cleanup === "none", `${s.id} has no {marker}`);
    if (/@/.test(s.prompt)) assert.ok(s.prompt.includes("ssdear@gmail.com"), `${s.id} emails someone other than the owner`);
  }
});

test("expand alternates cold and warm launches and inserts predecessors", () => {
  const banks = [{ file: "t.json", connector: "t", provider: "device", scenarios: [
    { id: "a", kind: "casual", prompt: "hi {marker}", expect: { outcome: "answer" } },
    { id: "b", kind: "followup", after: "a", prompt: "more", expect: { outcome: "answer" } },
  ] }];
  const steps = expand(select(banks, { scenarioIds: ["b"] }), banks, { repeats: 3, marker: "qa1" });
  assert.deepEqual(steps.map((s) => [s.stepKey, s.launch, s.role]), [
    ["b#1/pre", "relaunch", "pre"], ["b#1", "continue", "main"],
    ["b#2/pre", "continue", "pre"], ["b#2", "continue", "main"],
    ["b#3/pre", "relaunch", "pre"], ["b#3", "continue", "main"],
  ]);
  assert.equal(steps[0].prompt, "hi qa1");
});

test("a pinned launch wins over alternation", () => {
  const banks = [{ file: "t.json", connector: "t", provider: "device", scenarios: [
    { id: "a", kind: "casual", launch: "continue", prompt: "hi", expect: { outcome: "answer" } },
  ] }];
  const steps = expand(allScenarios(banks), banks, { repeats: 2, marker: "m" });
  assert.deepEqual(steps.map((s) => s.launch), ["continue", "continue"]);
});

test("validate names the problems", () => {
  const problems = validate([{ file: "x.json", connector: "x", provider: "nope", scenarios: [
    { id: "q", kind: "odd", prompt: "", expect: { outcome: "maybe" } },
    { id: "q", kind: "followup", prompt: "p", expect: { outcome: "answer" } },
  ] }]);
  assert.ok(problems.some((p) => p.includes("provider")));
  assert.ok(problems.some((p) => p.includes("duplicate")));
  assert.ok(problems.some((p) => p.includes("followup needs after")));
});

test("markers are lowercase alphanumerics safe for Drive and Outlook queries", () => {
  assert.match(newMarker(), /^qa[0-9]{12}[0-9a-f]{4}$/);
});
