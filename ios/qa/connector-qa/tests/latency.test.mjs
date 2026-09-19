import { test } from "node:test";
import assert from "node:assert/strict";
import { budget, summarize, turnsFrom } from "../lib/latency.mjs";

const at = (t, message) => ({ t, message });

test("a turn's budget splits model time from tool time around each tool call", () => {
  const lines = [
    at(0.0, "[gateway] sent chat request id=a"),
    at(0.4, "[chat-timing] phase=accepted elapsedMs=400 outcome=none"),
    at(9.4, "[gateway] activity tool=gmail_messages command=connections.read phase=start elapsedMs=9400"),
    at(9.9, "[gateway] activity tool=gmail_messages phase=result error=false elapsedMs=9900"),
    at(12.4, "[chat-timing] phase=first-text elapsedMs=12400 outcome=none"),
    at(13.0, "[chat-timing] phase=terminal elapsedMs=13000 outcome=reply"),
  ];
  const [turn] = turnsFrom(lines);
  assert.deepEqual(budget(turn), {
    tools: ["connections.read"], modelSegments: [9, 2.5], modelSeconds: 11.5,
    toolSeconds: 0.5, toFirstText: 12, total: 13, outcome: "reply",
  });
});

test("the node's own lines stand in for activity lines on builds without them, never both", () => {
  const withNodeOnly = turnsFrom([
    at(0, "[gateway] sent chat request id=a"),
    at(1, "[chat-timing] phase=accepted elapsedMs=1000 outcome=none"),
    at(5, "[location-node] handling command=device.status id=1"),
    at(5.1, "[location-node] sent result id=1"),
    at(7, "[chat-timing] phase=first-text elapsedMs=7000 outcome=none"),
    at(7.5, "[chat-timing] phase=terminal elapsedMs=7500 outcome=reply"),
  ]);
  assert.deepEqual(budget(withNodeOnly[0]).tools, ["device.status"]);

  const withBoth = turnsFrom([
    at(0, "[gateway] sent chat request id=a"),
    at(1, "[chat-timing] phase=accepted elapsedMs=1000 outcome=none"),
    at(5, "[gateway] activity tool=device_status command=device.status phase=start elapsedMs=5000"),
    at(5.05, "[location-node] handling command=device.status id=1"),
    at(5.1, "[location-node] sent result id=1"),
    at(5.2, "[gateway] activity tool=device_status phase=result error=false elapsedMs=5200"),
    at(7, "[chat-timing] phase=first-text elapsedMs=7000 outcome=none"),
    at(7.5, "[chat-timing] phase=terminal elapsedMs=7500 outcome=reply"),
  ]);
  const b = budget(withBoth[0]);
  assert.deepEqual(b.tools, ["device.status"]);
  assert.equal(b.toolSeconds, 0.2);
});

test("a built-in tool with no invoke command is named after the tool", () => {
  const [turn] = turnsFrom([
    at(0, "[gateway] sent chat request id=a"),
    at(1, "[chat-timing] phase=accepted elapsedMs=1000 outcome=none"),
    at(4, "[gateway] activity tool=web_search command=- phase=start elapsedMs=4000"),
    at(6, "[gateway] activity tool=web_search phase=result error=false elapsedMs=6000"),
    at(8, "[chat-timing] phase=first-text elapsedMs=8000 outcome=none"),
    at(8.2, "[chat-timing] phase=terminal elapsedMs=8200 outcome=reply"),
  ]);
  assert.deepEqual(budget(turn).tools, ["web_search"]);
});

test("a turn the log ends inside is dropped; a failed turn keeps its outcome", () => {
  const turns = turnsFrom([
    at(0, "[gateway] sent chat request id=a"),
    at(1, "[chat-timing] phase=accepted elapsedMs=1000 outcome=none"),
    at(2, "[chat-timing] phase=terminal elapsedMs=2000 outcome=failed"),
    at(10, "[gateway] sent chat request id=b"),
    at(11, "[chat-timing] phase=accepted elapsedMs=1000 outcome=none"),
  ]);
  assert.equal(turns.length, 1);
  assert.equal(budget(turns[0]).outcome, "failed");
  assert.equal(budget(turns[0]).toFirstText, null);
});

test("summarize reports medians over replies only and the tool share of wall time", () => {
  const s = summarize([
    { tools: ["x"], modelSegments: [8, 2], modelSeconds: 10, toolSeconds: 1, toFirstText: 11, total: 12, outcome: "reply" },
    { tools: ["x"], modelSegments: [4, 2], modelSeconds: 6, toolSeconds: 1, toFirstText: 7, total: 8, outcome: "reply" },
    { tools: [], modelSegments: [2], modelSeconds: 2, toolSeconds: 0, toFirstText: 2, total: 3, outcome: "reply" },
    { tools: [], modelSegments: [], modelSeconds: 0, toolSeconds: 0, toFirstText: null, total: 0.3, outcome: "failed" },
  ]);
  assert.equal(s.turns, 3);
  assert.equal(s.medianTotal, 8);
  assert.equal(s.toolShare, 8.7);
  assert.equal(s.withTools.medianFirstDecision, 6);
  assert.equal(s.withTools.medianRoundTrips, 2);
  assert.equal(s.withoutTools.medianTotal, 3);
});
