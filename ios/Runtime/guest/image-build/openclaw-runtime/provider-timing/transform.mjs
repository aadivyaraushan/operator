import { createHash } from 'node:crypto';

const loggerImport = 'import { t as createSubsystemLogger } from "./subsystem-bfHYmnCE.js";\n';
const support = `// operator-provider-timing:start
const operatorProviderTimings = new WeakMap();
let operatorProviderSequence = 0;
function operatorProviderTimingWrite(record) {
  try {
    createSubsystemLogger("operator/provider-timing").info("[provider-timing] " + JSON.stringify(record));
  } catch {
    // Measurement must not interrupt the existing provider call.
  }
}
function operatorProviderTimingStart(state, startedAt, requestTimeoutMs) {
  const call = ++operatorProviderSequence;
  operatorProviderTimings.set(state, { call, startedAt, first: false });
  const limit = typeof requestTimeoutMs === "number" && Number.isFinite(requestTimeoutMs) && requestTimeoutMs > 0 ? requestTimeoutMs : null;
  operatorProviderTimingWrite({ phase: "start", call, elapsedMs: 0, requestTimeoutMs: limit });
}
function operatorProviderTimingMark(state, phase) {
  const timing = operatorProviderTimings.get(state);
  if (!timing) return;
  if (phase === "first") {
    if (timing.first) return;
    timing.first = true;
  }
  operatorProviderTimingWrite({ phase, call: timing.call, elapsedMs: Math.max(0, Date.now() - timing.startedAt) });
  if (phase !== "first") operatorProviderTimings.delete(state);
}
// operator-provider-timing:end
`;
const specs = [
  ['createModelLifecycle', '8df081e3d3dbb27f9e83dc60dd05a0f7f5b0466cb7c06b8236122f877a35b3a8', '\tconst startedAt = Date.now();', '\tconst startedAt = Date.now();\n\toperatorProviderTimingStart(observer.state, startedAt, params.requestTimeoutMs);'],
  ['emitModelCallEnded', 'ea2cfdb743ae1ff64c28d8af9f3d5cba73281438fee0ca3aadbded0f224b3080', '\tobserver.state.terminalEventEmitted = true;', '\tobserver.state.terminalEventEmitted = true;\n\toperatorProviderTimingMark(observer.state, failure ? "error" : "completed");'],
  ...[
    ['observeResponseChunk', 'aca967f62e903969754d142ae27291b7aa6e31249fb1a111d63736c00a8cf200'],
    ['observeResultMessageContent', '37950f1f428200954ff3a0bc5f4714f4984c97042d9535f698a524dcdb6253bf'],
  ].map(([name, hash]) => [name, hash, '\tstate.timeToFirstByteMs ??= Math.max(0, Date.now() - startedAt);', '\tstate.timeToFirstByteMs ??= Math.max(0, Date.now() - startedAt);\n\toperatorProviderTimingMark(state, "first");']),
];
const digest = text => createHash('sha256').update(text).digest('hex');
function replaceExactly(text, from, to) {
  if (text.split(from).length !== 2) throw new Error('Unsupported provider timing source shape');
  return text.replace(from, to);
}
export function transform(source) {
  const repeated = source.includes('// operator-provider-timing:');
  let result = repeated ? replaceExactly(source, loggerImport + support, '') : source;
  for (const [name, hash, from, to] of specs) {
    const anchor = `function ${name}(`;
    const start = result.indexOf(anchor), end = result.indexOf('\n}', start) + 2;
    if (start < 0 || end < 2 || result.indexOf(anchor, start + 1) >= 0) throw new Error('Unsupported provider timing function');
    const current = result.slice(start, end);
    const original = repeated ? replaceExactly(current, to, from) : current;
    if (digest(original) !== hash) throw new Error('Unsupported provider timing source; pinned function differs');
    const changed = replaceExactly(original, from, to);
    result = result.slice(0, start) + changed + result.slice(end);
  }
  if (result.includes(loggerImport) || result.includes('// operator-provider-timing:')) throw new Error('Unsupported provider timing duplicate support');
  return loggerImport + support + result;
}
