const recoverySourceRuns = new Map();

function normalized(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

export function registerNativeRecoverySourceRun(recoveryRunId, sourceRunId) {
  recoveryRunId = normalized(recoveryRunId);
  sourceRunId = normalized(sourceRunId);
  if (!recoveryRunId || !sourceRunId) throw new Error('[operator-native/recovery] run IDs must be non-empty');
  if (recoveryRunId === sourceRunId) throw new Error('[operator-native/recovery] recovery and source run IDs must differ');
  const existing = recoverySourceRuns.get(recoveryRunId);
  if (existing && existing !== sourceRunId) throw new Error('[operator-native/recovery] conflicting source run mapping');
  recoverySourceRuns.set(recoveryRunId, sourceRunId);
}

export function attachNativeRecoverySourceRunId(message, runId) {
  const sourceRunId = recoverySourceRuns.get(normalized(runId));
  if (!sourceRunId || !message || typeof message !== 'object' || Array.isArray(message)) return message;
  const current = message.__openclaw;
  const metadata = current && typeof current === 'object' && !Array.isArray(current) ? current : {};
  if (metadata.sourceRunId && metadata.sourceRunId !== sourceRunId) {
    throw new Error('[operator-native/recovery] conflicting persisted source run mapping');
  }
  if (metadata.sourceRunId === sourceRunId) return message;
  return {...message, __openclaw: {...metadata, sourceRunId}};
}

export function projectNativeOperatorRecovery(entry) {
  if (!entry || entry.status !== 'running' || entry.restartRecoverySourceIngress !== 'control-ui') return;
  const sourceRunId = normalized(entry.restartRecoveryDeliverySourceRunId);
  const runId = normalized(entry.restartRecoveryDeliveryRunId);
  if (!sourceRunId || !runId || !(entry.abortedLastRun === true || runId !== sourceRunId)) return;
  return {sourceRunId, runId};
}

export function clearNativeRecoverySourceRunsForTest() {
  recoverySourceRuns.clear();
}

export function patchNativeRecoveryRegistration(source) {
  const importLine = 'import { registerNativeRecoverySourceRun } from "./native-recovery-source-run.mjs";';
  const marker = '\n\t\tconst agentParams = {';
  const injection = '\n\t\tif (params.entry.restartRecoverySourceIngress === "control-ui" && sourceRunId && recoveryRunId !== sourceRunId) registerNativeRecoverySourceRun(recoveryRunId, sourceRunId);';
  const count = value => source.split(value).length - 1;
  const contract = [
    'async function resumeMainSession(params)',
    'entry.restartRecoveryDeliveryRunId = recoveryRunId;',
    'const sourceRunId = normalizeOptionalString(params.entry.restartRecoveryDeliverySourceRunId);',
    marker,
  ];
  const patched = count(importLine) === 1 && count(injection) === 1;
  if (patched && contract.every(value => count(value) === 1)) return source;
  if (contract.some(value => count(value) !== 1) || source.includes(importLine) || source.includes(injection)) {
    throw new Error('[operator-native/recovery] Pinned OpenClaw recovery changed; registration patch refused');
  }
  return `${importLine}\n${source}`.replace(marker, `${injection}${marker}`);
}

export function patchNativeTranscriptRecoverySource(source) {
  const importLine = 'import { attachNativeRecoverySourceRunId } from "./native-recovery-source-run.mjs";';
  const original = `function attachSessionTranscriptRunId(message, runId) {
\tconst normalizedRunId = normalizeOptionalString(runId);
\tif (!normalizedRunId || !isRecord(message) || message.role !== "assistant" && message.role !== "toolResult") return message;
\tconst metadata = isRecord(message["__openclaw"]) ? message["__openclaw"] : {};
\tif (metadata.runId === normalizedRunId) return message;
\treturn {
\t\t...message,
\t\t__openclaw: {
\t\t\t...metadata,
\t\t\trunId: normalizedRunId
\t\t}
\t};
}`;
  const replacement = `function attachSessionTranscriptRunId(message, runId) {
\tconst normalizedRunId = normalizeOptionalString(runId);
\tif (!normalizedRunId || !isRecord(message) || message.role !== "assistant" && message.role !== "toolResult") return message;
\tconst metadata = isRecord(message["__openclaw"]) ? message["__openclaw"] : {};
\tconst messageWithRunId = metadata.runId === normalizedRunId ? message : {
\t\t...message,
\t\t__openclaw: {
\t\t\t...metadata,
\t\t\trunId: normalizedRunId
\t\t}
\t};
\treturn attachNativeRecoverySourceRunId(messageWithRunId, normalizedRunId);
}`;
  const importCount = source.split(importLine).length - 1;
  const replacementCount = source.split(replacement).length - 1;
  if (importCount === 1 && replacementCount === 1 && !source.includes(original)) return source;
  if (source.split(original).length - 1 !== 1 || importCount !== 0 || replacementCount !== 0) {
    throw new Error('[operator-native/recovery] Pinned OpenClaw transcript changed; source-run patch refused');
  }
  return `${importLine}\n${source.replace(original, replacement)}`;
}

export function patchNativeChatHistoryRecovery(source) {
  const importLine = 'import { projectNativeOperatorRecovery } from "./native-recovery-source-run.mjs";';
  const anchor = '\tconst embeddedRecovery = resolveEmbeddedAgentRunRecoverySnapshot({';
  const declaration = '\tconst operatorRecovery = projectNativeOperatorRecovery(historyEntry);\n';
  const spreadAnchor = '\n\t\t\t...boundedInFlightRun ? { inFlightRun: boundedInFlightRun } : {},';
  const spread = '\n\t\t\t...operatorRecovery ? { operatorRecovery } : {},';
  const normalAnchor = '\n\t\t...boundedInFlightRun ? { inFlightRun: boundedInFlightRun } : {},';
  const normalSpread = '\n\t\t...operatorRecovery ? { operatorRecovery } : {},';
  const count = value => source.split(value).length - 1;
  const patched = count(importLine) === 1 && count(declaration) === 1 && count(spread) === 1 && count(normalSpread) === 1;
  if (patched && count(anchor) === 1 && count(spreadAnchor) === 1 && count(normalAnchor) === 1) return source;
  if (count(anchor) !== 1 || count(spreadAnchor) !== 1 || count(normalAnchor) !== 1 || source.includes(importLine) || source.includes(declaration)) {
    throw new Error('[operator-native/recovery] Pinned OpenClaw chat history changed; recovery projection patch refused');
  }
  return `${importLine}\n${source}`
    .replace(anchor, `${declaration}${anchor}`)
    .replace(spreadAnchor, `${spread}${spreadAnchor}`)
    .replace(normalAnchor, `${normalSpread}${normalAnchor}`);
}

export function patchNativeIOSRestartSafeAdmission(source) {
  const original = 'eligible: isBrowserOperatorUiClient(request.clientInfo) && turnKind === "main" && normalizedAttachments.length === 0 && !request.reconnectResumeRequested && explicitOrigin === void 0 && p.deliver !== true && p.thinking === void 0 && p.fastMode === void 0 && p.fastAutoOnSeconds === void 0 && p.timeoutMs === void 0 && request.systemInputProvenance === void 0 && request.systemProvenanceReceipt === void 0 && !request.suppressCommandInterpretation,';
  const replacement = 'eligible: (isBrowserOperatorUiClient(request.clientInfo) || request.clientInfo?.id === "openclaw-ios") && turnKind === "main" && normalizedAttachments.length === 0 && !request.reconnectResumeRequested && explicitOrigin === void 0 && p.deliver !== true && p.thinking === void 0 && p.fastMode === void 0 && p.fastAutoOnSeconds === void 0 && p.timeoutMs === void 0 && request.systemInputProvenance === void 0 && request.systemProvenanceReceipt === void 0 && !request.suppressCommandInterpretation,';
  const count = value => source.split(value).length - 1;
  const contract = [
    'function createRestartSafeChatRequest(params)',
    'const restartSafeRequest = createRestartSafeChatRequest({',
    'message: rawMessage,',
    'senderIsOwner: hasGatewayAdminScope(client)',
  ];
  if (count(replacement) === 1 && count(original) === 0 && contract.every(value => count(value) === 1)) return source;
  if (count(original) !== 1 || count(replacement) !== 0 || contract.some(value => count(value) !== 1)) {
    throw new Error('[operator-native/recovery] Pinned OpenClaw chat admission changed; iOS restart-safe patch refused');
  }
  return source.replace(original, replacement);
}
