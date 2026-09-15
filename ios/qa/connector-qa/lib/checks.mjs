// Mechanical checks. These decide pass / fail / blocked from the log and the
// persisted reply before any LLM judges anything. A reply on its own never
// passes a scenario.

export const FAILURE_PHRASES = [
  "not connected", "isn't connected", "is not connected", "can't access", "cannot access",
  "unable to access", "don't have access", "do not have access", "no access to your",
  "couldn't access", "could not access", "need to connect", "please connect",
  "something went wrong", "an error occurred", "encountered an error", "failed to",
  "try again later", "not able to",
];

// Environment, not connector: sign-in lost, keychain, provider rate limit.
// A revoked scope (403) is a connector fail and stays out of this list.
const BLOCKED_LOG = [
  /notConnected/i, /NOT_CONNECTED/, /not connected on this device/i, /RATE_LIMITED/, /rateLimited/,
  /KeychainStoreError/,
];

/// Commands that change something outside the phone. Clarify and decline
/// scenarios forbid these unless the bank says otherwise. `sms.send` is the
/// no-tap text: it goes out through the owner's shortcut with no composer.
export const WRITE_COMMANDS = ["connections.write", "whatsapp.compose", "sms.compose", "sms.send"];

/// The app's own permission layer refused a command because the owner has not
/// granted that connector. The model is told to stop, so the turn cannot show
/// what the connector does; the driver grants from the banner and the step
/// is scored blocked, like a missing sign-in.
const DENIED = /\[permissions\] denied connector=(\S+) access=(\S+)/;

const NEGATIONS = /(?:\b(?:not|never|no|nothing|without|didn't|did not|wasn't|was not|haven't|have not|hasn't|has not|won't|will not|isn't|is not|couldn't|could not|can't|cannot|unable to|rather than|instead of)\b[^.!?\n]{0,40})$/i;

/// True when `phrase` occurs in `text` as an affirmative statement, i.e. not
/// within a few words after a negation ("I did not create it" does not count).
export function containsAffirmative(text, phrase) {
  const hay = lower(text);
  const needle = lower(phrase);
  let from = 0;
  while (true) {
    const i = hay.indexOf(needle, from);
    if (i < 0) return false;
    if (!NEGATIONS.test(hay.slice(Math.max(0, i - 60), i))) return true;
    from = i + needle.length;
  }
}

const BLOCKED_REPLY = [/rate limit/i, /usage limit/i, /too many requests/i];

const lower = (s) => (s ?? "").toLowerCase();

/// Pulls the facts out of the log lines that fell inside one step's window.
export function summarizeLog(lines) {
  const commands = [];
  const operations = [];
  const responses = [];
  const rejected = [];
  const blockedHits = [];
  const denied = [];
  for (const { message } of lines) {
    let m;
    if ((m = message.match(/handling command=(\S+)/))) commands.push(m[1]);
    if ((m = message.match(DENIED))) denied.push(`${m[1]}:${m[2]}`);
    if ((m = message.match(/\[account-(read|write)\] request .*?operation=(\w+)/))) operations.push(m[2]);
    if ((m = message.match(/\[account-(read|write)\] response .*?operation=(\w+).*?status=(\d+)/))) {
      responses.push({ operation: m[2], status: Number(m[3]) });
    }
    if (/rejected/.test(message)) rejected.push(message);
    for (const re of BLOCKED_LOG) if (re.test(message)) { blockedHits.push(message); break; }
  }
  return { commands, operations, responses, rejected, blockedHits, denied };
}

/// `scenario` is the bank entry (with expect); `step` is the driver line;
/// `reply` is the persisted assistant text; `lines` the log window.
export function evaluate(scenario, step, reply, lines) {
  const e = scenario.expect;
  const log = summarizeLog(lines);
  const checks = [];
  const add = (name, pass, detail = "") => checks.push({ name, pass, detail });
  const approve = step.approve ?? scenario.approve ?? "allow";
  const replyLower = lower(reply);

  if (step.error?.startsWith("blocked:")) {
    return { checks: [{ name: "driver", pass: false, detail: step.error }], mechanical: "blocked", log };
  }
  if (step.error?.startsWith("app-crashed")) {
    add("app-alive", false, step.error);
    return { checks, mechanical: "fail", log };
  }
  const blockedReply = BLOCKED_REPLY.some((re) => re.test(reply ?? ""));
  if (log.blockedHits.length || blockedReply) {
    add("blocked", false, log.blockedHits[0] ?? "reply mentions a rate or usage limit");
    return { checks, mechanical: "blocked", log };
  }
  // A decline scenario is the one place a refusal by the permission layer is
  // a valid outcome: the app said no, which is what the scenario wants to see.
  if (log.denied.length && e.outcome !== "decline") {
    add("grant-missing", false, `owner has not granted ${log.denied.join(",")}; the driver allowed it from the banner, rerun this scenario`);
    return { checks, mechanical: "blocked", log };
  }

  add("reply-present", Boolean(reply?.trim()), step.error ?? `${(reply ?? "").length} chars`);

  if (e.commands_any?.length) {
    const hit = e.commands_any.filter((c) => log.commands.includes(c));
    add("commands-any", hit.length > 0, `expected one of ${e.commands_any.join("|")}; fired ${log.commands.join(",") || "none"}`);
  }
  // A denied write is allowed to fire the command; the Cancel tap is the guard.
  const commandsNone = e.commands_none ?? (["clarify", "decline"].includes(e.outcome) && approve !== "deny" ? WRITE_COMMANDS : []);
  if (commandsNone.length) {
    const bad = commandsNone.filter((c) => log.commands.includes(c));
    add("commands-none", bad.length === 0, bad.length ? `forbidden fired: ${bad.join(",")}` : "");
  }
  if (e.operations_any?.length && approve !== "deny") {
    const hit = e.operations_any.filter((o) => log.operations.includes(o));
    add("operations-any", hit.length > 0, `expected one of ${e.operations_any.join("|")}; saw ${log.operations.join(",") || "none"}`);
  }
  if (e.outcome === "answer" && approve !== "deny") {
    const bad = log.responses.filter((r) => r.status < 200 || r.status >= 300);
    add("status-2xx", bad.length === 0, bad.map((r) => `${r.operation}=${r.status}`).join(",") || `${log.responses.length} responses`);
    if (e.operations_any?.length) add("response-seen", log.responses.length > 0, `${log.responses.length} provider responses`);
    const rej = log.rejected.filter((m) => /account-(read-service|write-confirmation)/.test(m));
    add("no-rejected", rej.length === 0, rej[0] ?? "");
  }

  const appAlerts = (step.alerts ?? []).filter((a) => a.source === "app");
  if (e.approval === "required") {
    const acted = appAlerts.filter((a) => a.action !== "left" && a.action !== "no-button");
    add("approval-seen", acted.length > 0, appAlerts.map((a) => `${a.title}:${a.action}`).join(";") || "no app alert");
    if (approve === "deny") add("approval-denied", acted.every((a) => /cancel|deny|don't/i.test(a.action)), acted.map((a) => a.action).join(","));
  } else if (e.approval === "none") {
    add("no-approval", appAlerts.length === 0, appAlerts.map((a) => a.title).join(";"));
  }

  const forbidden = [...(e.reply_must_not_contain ?? [])];
  if (e.outcome === "answer" || e.outcome === "handoff") forbidden.push(...FAILURE_PHRASES);
  const hits = forbidden.filter((p) => containsAffirmative(reply, p));
  add("no-failure-phrase", hits.length === 0, hits.join(","));
  if (e.reply_must_contain_any?.length) {
    add("reply-contains", e.reply_must_contain_any.some((p) => replyLower.includes(lower(p))), e.reply_must_contain_any.join("|"));
  }
  if (e.outcome === "clarify") add("asks-a-question", replyLower.includes("?"), "");

  const mechanical = checks.every((c) => c.pass) ? "pass" : "fail";
  return { checks, mechanical, log };
}

/// Combines the main-step results of one scenario across repeats.
export function aggregate(stepVerdicts) {
  const v = stepVerdicts;
  if (v.length === 0) return "blocked";
  if (v.every((x) => x === "pass")) return "pass";
  if (v.every((x) => x === "fail")) return "fail";
  if (v.some((x) => x === "fail")) return v.some((x) => x === "pass") ? "flaky" : "fail";
  return "blocked";
}
