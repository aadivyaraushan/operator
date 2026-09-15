import { test } from "node:test";
import assert from "node:assert/strict";
import { evaluate, aggregate, summarizeLog } from "../lib/checks.mjs";

const line = (message) => ({ t: 1, category: "x", message });
const readScenario = {
  id: "gmail-casual", kind: "casual", provider: "google",
  expect: { outcome: "answer", commands_any: ["connections.read"], operations_any: ["gmailMessages"], commands_none: ["connections.write"], approval: "none" },
};
const goodLog = [
  line("[location-node] handling command=connections.read id=1"),
  line("[account-read] request provider=google operation=gmailMessages limit=5"),
  line("[account-read] response provider=google operation=gmailMessages status=200 count=3"),
];

test("a read that fired, returned 200 and replied with data passes", () => {
  const r = evaluate(readScenario, { approve: "allow", alerts: [] }, "Your latest email is from Ann: Lunch?", goodLog);
  assert.equal(r.mechanical, "pass", JSON.stringify(r.checks));
});

test("reply text alone never passes: no command in the log is a fail", () => {
  const r = evaluate(readScenario, { approve: "allow", alerts: [] }, "Your latest email is from Ann: Lunch?", []);
  assert.equal(r.mechanical, "fail");
  assert.ok(r.checks.find((c) => c.name === "commands-any" && !c.pass));
});

test("a non-2xx response fails even when the reply sounds fine", () => {
  const log = [goodLog[0], goodLog[1], line("[account-read] response provider=google operation=gmailMessages status=401")];
  const r = evaluate(readScenario, { approve: "allow", alerts: [] }, "Here are your emails", log);
  assert.equal(r.mechanical, "fail");
  assert.ok(r.checks.find((c) => c.name === "status-2xx" && !c.pass));
});

test("a failure phrase in the reply fails an answer scenario", () => {
  const r = evaluate(readScenario, { approve: "allow", alerts: [] }, "I couldn't access your inbox.", goodLog);
  assert.ok(r.checks.find((c) => c.name === "no-failure-phrase" && !c.pass));
  assert.equal(r.mechanical, "fail");
});

test("a read that fired a write is a fail", () => {
  const log = [...goodLog, line("[location-node] handling command=connections.write id=2")];
  const r = evaluate(readScenario, { approve: "allow", alerts: [] }, "done", log);
  assert.ok(r.checks.find((c) => c.name === "commands-none" && !c.pass));
});

test("not connected in the log is blocked, not fail", () => {
  const log = [goodLog[0], line("[account-read-service] rejected result=notConnected(provider: google)")];
  const r = evaluate(readScenario, { approve: "allow", alerts: [] }, "Gmail isn't connected yet.", log);
  assert.equal(r.mechanical, "blocked");
});

test("a driver blocked error is blocked", () => {
  const r = evaluate(readScenario, { approve: "allow", alerts: [], error: "blocked:model-not-signed-in" }, "", []);
  assert.equal(r.mechanical, "blocked");
});

const writeScenario = {
  id: "gcal-write", kind: "write", provider: "google",
  expect: { outcome: "answer", commands_any: ["connections.write"], operations_any: ["googleCalendarCreateEvent"], approval: "required" },
};
const writeLog = [
  line("[location-node] handling command=connections.write id=3"),
  line("[account-write] request provider=google operation=googleCalendarCreateEvent"),
  line("[account-write] response provider=google operation=googleCalendarCreateEvent status=200"),
];

test("a write needs an approval alert that was allowed", () => {
  const ok = evaluate(writeScenario, { approve: "allow", alerts: [{ source: "app", title: "Allow account action?", action: "Allow" }] }, "Created the event.", writeLog);
  assert.equal(ok.mechanical, "pass", JSON.stringify(ok.checks));
  const noAlert = evaluate(writeScenario, { approve: "allow", alerts: [] }, "Created the event.", writeLog);
  assert.ok(noAlert.checks.find((c) => c.name === "approval-seen" && !c.pass));
});

test("a denied write passes only when the reply does not claim success", () => {
  const deny = { ...writeScenario, expect: { ...writeScenario.expect, outcome: "decline", reply_must_not_contain: ["created"] } };
  const alerts = [{ source: "app", title: "Allow account action?", action: "Cancel" }];
  const honest = evaluate(deny, { approve: "deny", alerts }, "You cancelled, so nothing was added.", [writeLog[0]]);
  assert.equal(honest.mechanical, "pass", JSON.stringify(honest.checks));
  const lying = evaluate(deny, { approve: "deny", alerts }, "Created the event.", [writeLog[0]]);
  assert.equal(lying.mechanical, "fail");
});

test("a clarify scenario must ask something and must not write", () => {
  const s = { id: "c", kind: "clarify", provider: "google", expect: { outcome: "clarify", commands_none: ["connections.write"], approval: "none" } };
  assert.equal(evaluate(s, { approve: "allow", alerts: [] }, "Who should I reply to?", []).mechanical, "pass");
  assert.equal(evaluate(s, { approve: "allow", alerts: [] }, "Done.", []).mechanical, "fail");
});

test("springboard permission prompts do not count as approval alerts", () => {
  const s = { id: "r", kind: "casual", provider: "device", expect: { outcome: "answer", commands_any: ["reminders.list"], approval: "none" } };
  const alerts = [{ source: "springboard", title: "“Operator” Would Like to Access Your Reminders", action: "Allow Full Access" }];
  const r = evaluate(s, { approve: "allow", alerts }, "You have 2 reminders.", [line("[location-node] handling command=reminders.list id=9")]);
  assert.equal(r.mechanical, "pass", JSON.stringify(r.checks));
});

test("aggregate: flaky is never rounded up", () => {
  assert.equal(aggregate(["pass", "pass", "pass"]), "pass");
  assert.equal(aggregate(["pass", "fail", "pass"]), "flaky");
  assert.equal(aggregate(["fail", "fail"]), "fail");
  assert.equal(aggregate(["blocked", "pass"]), "blocked");
  assert.equal(aggregate(["blocked", "fail"]), "fail");
});

test("summarizeLog reads commands, operations and statuses", () => {
  const s = summarizeLog(goodLog);
  assert.deepEqual(s.commands, ["connections.read"]);
  assert.deepEqual(s.operations, ["gmailMessages"]);
  assert.deepEqual(s.responses, [{ operation: "gmailMessages", status: 200 }]);
});

test("a negated phrase is not a claim of success", () => {
  const deny = { ...writeScenario, expect: { ...writeScenario.expect, outcome: "decline", reply_must_not_contain: ["created"] } };
  const alerts = [{ source: "app", title: "Allow account action?", action: "Cancel" }];
  const r = evaluate(deny, { approve: "deny", alerts }, "I did not create the event because you cancelled.", [writeLog[0]]);
  assert.equal(r.mechanical, "pass", JSON.stringify(r.checks));
  const r2 = evaluate(deny, { approve: "deny", alerts }, "Not a problem. I created the event.", [writeLog[0]]);
  assert.equal(r2.mechanical, "fail");
});

test("clarify and decline forbid writes even when the bank forgot commands_none", () => {
  const s = { id: "c", kind: "clarify", provider: "google", expect: { outcome: "clarify", approval: "any" } };
  const r = evaluate(s, { approve: "allow", alerts: [] }, "Sure, who to?", [line("[location-node] handling command=whatsapp.compose id=1")]);
  assert.ok(r.checks.find((c) => c.name === "commands-none" && !c.pass));
});

test("an answer that expects an operation needs a provider response line", () => {
  const log = [goodLog[0], goodLog[1]];
  const r = evaluate(readScenario, { approve: "allow", alerts: [] }, "Latest is from Ann.", log);
  assert.ok(r.checks.find((c) => c.name === "response-seen" && !c.pass));
});

test("a 403 scope failure is a fail, not blocked", () => {
  const log = [goodLog[0], line("[account-read-service] rejected result=permissionDenied")];
  const r = evaluate(readScenario, { approve: "allow", alerts: [] }, "I can't read that.", log);
  assert.equal(r.mechanical, "fail");
});

test("an app crash during the turn is a fail, never blocked", () => {
  const r = evaluate(readScenario, { approve: "allow", alerts: [], error: "app-crashed: not running" }, "", []);
  assert.equal(r.mechanical, "fail");
  assert.ok(r.checks.find((c) => c.name === "app-alive" && !c.pass));
});
