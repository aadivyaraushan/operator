// A turn's latency budget, read from the app log. Where the seconds go: the
// model deciding to call a tool, the tool itself, the model writing after.
//
// The phases come from two kinds of line. `[chat-timing]` marks accepted,
// first-text and terminal. Tool calls come from `[gateway] activity tool=…
// phase=start|result` (every tool, including OpenClaw's own such as web
// search) and, on builds before that line existed, from the node's own
// `[location-node] handling command=… / sent result` pair, which sees only
// phone commands. When both are present the gateway line wins so a tool is
// never counted twice.

const SENT = /^\[gateway\] sent chat request/;
const ACCEPTED = /^\[chat-timing\] phase=accepted/;
const FIRST_TEXT = /^\[chat-timing\] phase=first-text/;
const TERMINAL = /^\[chat-timing\] phase=terminal .*outcome=(\S+)/;
const ACTIVITY_START = /^\[gateway\] activity tool=(\S+) command=(\S+) phase=start/;
const ACTIVITY_RESULT = /^\[gateway\] activity tool=(\S+) phase=result/;
const NODE_START = /^\[location-node\] handling command=(\S+)/;
const NODE_RESULT = /^\[location-node\] sent result/;

/// Splits parsed log lines ({t, message}) into turns. A turn without a
/// terminal line (the log ended mid-turn) is dropped.
export function turnsFrom(lines) {
  const turns = [];
  let cur = null;
  let usesActivity = false;
  for (const { t, message } of lines) {
    if (SENT.test(message)) {
      if (cur?.terminal) turns.push(cur);
      cur = { sent: t, tools: [] };
      usesActivity = false;
      continue;
    }
    if (!cur) continue;
    let m;
    if (ACCEPTED.test(message)) cur.accepted = t;
    else if ((m = message.match(ACTIVITY_START))) {
      usesActivity = true;
      cur.tools.push({ tool: m[1], command: m[2] === "-" ? m[1] : m[2], start: t });
    } else if (ACTIVITY_RESULT.test(message)) close(cur, t);
    else if (!usesActivity && (m = message.match(NODE_START))) cur.tools.push({ tool: m[1], command: m[1], start: t });
    else if (!usesActivity && NODE_RESULT.test(message)) close(cur, t);
    else if (FIRST_TEXT.test(message)) cur.firstText = t;
    else if ((m = message.match(TERMINAL))) { cur.terminal = t; cur.outcome = m[1]; }
  }
  if (cur?.terminal) turns.push(cur);
  return turns;
}

function close(turn, t) {
  const open = [...turn.tools].reverse().find((x) => x.end === undefined);
  if (open) open.end = t;
}

/// One row per accepted turn: the model segments (accepted → first tool,
/// each tool's end → the next start, last tool → first text), the summed
/// tool time, and the totals. Seconds, one decimal.
export function budget(turn) {
  const tools = turn.tools.filter((x) => x.end !== undefined);
  const segments = [];
  let prev = turn.accepted;
  for (const x of tools) { segments.push(x.start - prev); prev = x.end; }
  if (turn.firstText !== undefined) segments.push(turn.firstText - prev);
  const r = (n) => Math.round(n * 10) / 10;
  return {
    tools: tools.map((x) => x.command),
    modelSegments: segments.map(r),
    modelSeconds: r(segments.reduce((a, b) => a + b, 0)),
    toolSeconds: r(tools.reduce((a, x) => a + (x.end - x.start), 0)),
    toFirstText: turn.firstText === undefined ? null : r(turn.firstText - turn.accepted),
    total: r(turn.terminal - turn.sent),
    outcome: turn.outcome,
  };
}

export function median(values) {
  const s = [...values].sort((a, b) => a - b);
  if (s.length === 0) return null;
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/// A short report over many turns. Replies only; failed turns say nothing
/// about where a finished reply's time goes.
export function summarize(budgets) {
  const ok = budgets.filter((b) => b.outcome === "reply" && b.toFirstText !== null);
  const withTools = ok.filter((b) => b.tools.length > 0);
  const total = ok.reduce((a, b) => a + b.total, 0);
  const tool = ok.reduce((a, b) => a + b.toolSeconds, 0);
  return {
    turns: ok.length,
    medianTotal: median(ok.map((b) => b.total)),
    medianToFirstText: median(ok.map((b) => b.toFirstText)),
    toolShare: total ? Math.round((1000 * tool) / total) / 10 : null,
    withTools: {
      turns: withTools.length,
      medianFirstDecision: median(withTools.map((b) => b.modelSegments[0])),
      medianRoundTrips: median(withTools.map((b) => b.modelSegments.length)),
      medianTotal: median(withTools.map((b) => b.total)),
    },
    withoutTools: {
      turns: ok.length - withTools.length,
      medianTotal: median(ok.filter((b) => b.tools.length === 0).map((b) => b.total)),
    },
  };
}

export function formatTable(rows) {
  const line = (r) => [
    r.at.padEnd(8), (r.tools.join(",") || "-").padEnd(36), String(r.toolSeconds).padStart(6),
    JSON.stringify(r.modelSegments).padEnd(26), String(r.modelSeconds).padStart(7),
    String(r.toFirstText).padStart(7), String(r.total).padStart(6), r.outcome,
  ].join(" ");
  const head = ["at".padEnd(8), "tools".padEnd(36), "tool s".padStart(6), "model segments (s)".padEnd(26),
    "model s".padStart(7), "1st txt".padStart(7), "total".padStart(6), "outcome"].join(" ");
  return [head, ...rows.map(line)].join("\n");
}
