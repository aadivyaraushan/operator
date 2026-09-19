import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

export const BUNDLE_ID = "app.operator.ios";
/// The owner's live Simulator: the one with the signed-in model and connected accounts.
export const DEFAULT_SIM = "49A153C3-BA69-468F-BD21-D827A84E6F07";
const APPLE_EPOCH = 978307200;

function simctl(args, opts = {}) {
  return execFileSync("xcrun", ["simctl", ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...opts }).trim();
}

export function ensureBooted(udid) {
  const list = JSON.parse(simctl(["list", "devices", "-j"]));
  const device = Object.values(list.devices).flat().find((d) => d.udid === udid);
  if (!device) throw new Error(`Simulator ${udid} not found on this Mac`);
  if (device.state !== "Booted") {
    simctl(["boot", udid]);
    simctl(["bootstatus", udid, "-b"]);
  }
  return device.name;
}

export function appInstalled(udid) {
  try { simctl(["get_app_container", udid, BUNDLE_ID]); return true; } catch { return false; }
}

/// Resolve this every time you read: the container id changes on reinstall.
export function conversationPath(udid) {
  const container = simctl(["get_app_container", udid, BUNDLE_ID, "data"]);
  return join(container, "Library", "Application Support", "Operator", "conversation.json");
}

export function readConversation(path) {
  if (!existsSync(path)) return { messages: [] };
  return JSON.parse(readFileSync(path, "utf8"));
}

/// The assistant messages that answered `prompt`, sent at or after `sentAt`
/// (epoch seconds). Returns the joined text and the message ids.
export function extractReply(conversation, prompt, sentAt) {
  const messages = conversation.messages ?? [];
  // Repeats send the same text, so take the first user message stamped at or
  // after this step's send, never the latest one.
  let index = -1;
  for (let i = 0; i < messages.length; i += 1) {
    const m = messages[i];
    if (m.role === "user" && m.text === prompt && m.createdAt + APPLE_EPOCH >= sentAt - 5) { index = i; break; }
  }
  if (index < 0) return { text: "", ids: [], userMessageId: null };
  const ids = [];
  const parts = [];
  for (let i = index + 1; i < messages.length; i += 1) {
    const m = messages[i];
    if (m.role === "user") break;
    ids.push(m.id);
    parts.push(m.attachment?.weather ? `[weather card: ${JSON.stringify(m.attachment.weather)}]` : m.text ?? "");
  }
  return { text: parts.join("\n\n").trim(), ids, userMessageId: messages[index].id };
}
