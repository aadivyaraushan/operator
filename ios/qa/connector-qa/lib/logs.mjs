import { spawn } from "node:child_process";
import { openSync, closeSync, readFileSync } from "node:fs";

const PREDICATE = 'subsystem == "app.operator.ios"';

/// Starts `log stream` for the app's subsystem, writing ndjson to `file`.
/// Simulator processes log into the Mac's unified log, so no udid is needed.
export function startLogStream(file) {
  const fd = openSync(file, "a");
  const child = spawn("log", ["stream", "--style", "ndjson", "--level", "info", "--predicate", PREDICATE],
    { stdio: ["ignore", fd, fd] });
  closeSync(fd);
  return {
    pid: child.pid,
    stop: () => new Promise((resolve) => { child.once("exit", resolve); child.kill("SIGTERM"); }),
  };
}

/// Parses an ndjson log file into {t, category, message}. Malformed lines are skipped.
export function parseLog(file) {
  const out = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.startsWith("{")) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    if (!obj.eventMessage) continue;
    out.push({ t: parseTimestamp(obj.timestamp), category: obj.category ?? "", message: obj.eventMessage });
  }
  return out;
}

/// "2026-09-14 19:42:01.123456-0500" -> epoch seconds.
export function parseTimestamp(s) {
  if (!s) return 0;
  const m = s.match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?([+-]\d{4})?$/);
  if (!m) return Date.parse(s) / 1000 || 0;
  const iso = `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}${m[7] ? "." + m[7].slice(0, 3) : ""}${m[8] ? m[8].slice(0, 3) + ":" + m[8].slice(3) : "Z"}`;
  return Date.parse(iso) / 1000;
}

export function window(lines, from, to) {
  return lines.filter((l) => l.t >= from && l.t <= to);
}
