import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {afterEach, test} from 'node:test';
import {
  attachNativeRecoverySourceRunId,
  clearNativeRecoverySourceRunsForTest,
  patchNativeRecoveryRegistration,
  patchNativeChatHistoryRecovery,
  patchNativeIOSRestartSafeAdmission,
  patchNativeTranscriptRecoverySource,
  projectNativeOperatorRecovery,
  registerNativeRecoverySourceRun,
} from '../source-run.mjs';

afterEach(clearNativeRecoverySourceRunsForTest);

test('adds the exact original source run only to its registered recovery run', () => {
  registerNativeRecoverySourceRun('recovery-1', 'source-1');
  const message = {role: 'assistant', __openclaw: {runId: 'recovery-1', kept: true}};
  assert.deepEqual(attachNativeRecoverySourceRunId(message, 'recovery-1'), {
    role: 'assistant', __openclaw: {runId: 'recovery-1', sourceRunId: 'source-1', kept: true},
  });
  assert.strictEqual(attachNativeRecoverySourceRunId(message, 'ordinary'), message);
});

test('preserves ordinary messages and existing metadata objects', () => {
  const ordinary = {role: 'assistant', __openclaw: {runId: 'ordinary'}};
  assert.strictEqual(attachNativeRecoverySourceRunId(ordinary, 'ordinary'), ordinary);
  registerNativeRecoverySourceRun('recovery-1', 'source-1');
  const withoutMetadata = {role: 'assistant'};
  assert.deepEqual(attachNativeRecoverySourceRunId(withoutMetadata, 'recovery-1'), {
    role: 'assistant', __openclaw: {sourceRunId: 'source-1'},
  });
});

test('metadata survives cloning and JSON serialization', () => {
  registerNativeRecoverySourceRun('recovery-1', 'source-1');
  const attached = attachNativeRecoverySourceRunId({role: 'toolResult', __openclaw: {runId: 'recovery-1'}}, 'recovery-1');
  assert.equal(structuredClone(attached).__openclaw.sourceRunId, 'source-1');
  assert.equal(JSON.parse(JSON.stringify(attached)).__openclaw.sourceRunId, 'source-1');
});

test('registration is repeatable but rejects conflicting source aliases', () => {
  registerNativeRecoverySourceRun('recovery-1', 'source-1');
  registerNativeRecoverySourceRun('recovery-1', 'source-1');
  assert.throws(() => registerNativeRecoverySourceRun('recovery-1', 'source-2'), /conflicting/i);
  assert.throws(() => registerNativeRecoverySourceRun('', 'source-1'), /non-empty/i);
  assert.throws(() => registerNativeRecoverySourceRun('same', 'same'), /differ/i);
});

const pristineDist = new URL('../../../../../build/runtime-recovery/openclaw-source/package/dist/', import.meta.url);
const recoverySource = readFileSync(new URL('main-session-restart-recovery--2blnuu5.js', pristineDist), 'utf8');
const transcriptSource = readFileSync(new URL('transcript-events-BMaG3A_w.js', pristineDist), 'utf8');
const chatSource = readFileSync(new URL('chat-D3QlhTHk.js', pristineDist), 'utf8');
const chatSendSource = readFileSync(new URL('chat-send-handler-DBjXcn_1.js', pristineDist), 'utf8');

function evaluateRestartSafeEligibility(source, overrides = {}) {
  const match = source.match(/eligible: ([^\n]+),\n\t\tmessage: rawMessage/);
  assert.ok(match, 'real pinned eligibility expression');
  const values = {
    request: {clientInfo: {id: 'openclaw-ios'}, reconnectResumeRequested: false, systemInputProvenance: undefined, systemProvenanceReceipt: undefined, suppressCommandInterpretation: false},
    turnKind: 'main', normalizedAttachments: [], explicitOrigin: undefined,
    p: {deliver: false, thinking: undefined, fastMode: undefined, fastAutoOnSeconds: undefined, timeoutMs: undefined},
    ...overrides,
  };
  values.request = {clientInfo: {id: 'openclaw-ios'}, reconnectResumeRequested: false, systemInputProvenance: undefined, systemProvenanceReceipt: undefined, suppressCommandInterpretation: false, ...overrides.request};
  values.p = {deliver: false, thinking: undefined, fastMode: undefined, fastAutoOnSeconds: undefined, timeoutMs: undefined, ...overrides.p};
  return Function(...Object.keys(values), 'isBrowserOperatorUiClient', `return Boolean(${match[1]})`)(
    ...Object.values(values), client => ['openclaw-control-ui', 'openclaw-browser-copilot'].includes(client?.id),
  );
}

test('extends only the real restart-safe eligibility gate to the native iOS client', () => {
  assert.equal(evaluateRestartSafeEligibility(chatSendSource), false);
  const patched = patchNativeIOSRestartSafeAdmission(chatSendSource);
  assert.equal(evaluateRestartSafeEligibility(patched), true);
  assert.equal(evaluateRestartSafeEligibility(patched, {request: {clientInfo: {id: 'openclaw-control-ui'}}}), true);
  assert.equal(evaluateRestartSafeEligibility(patched, {request: {clientInfo: {id: 'other-client'}}}), false);
  for (const excluded of [
    {turnKind: 'followup'}, {normalizedAttachments: [{}]}, {request: {reconnectResumeRequested: true}}, {explicitOrigin: {}},
    {p: {deliver: true}}, {p: {thinking: 'high'}}, {p: {fastMode: true}}, {p: {fastAutoOnSeconds: 1}}, {p: {timeoutMs: 1}},
    {request: {systemInputProvenance: {}}}, {request: {systemProvenanceReceipt: {}}}, {request: {suppressCommandInterpretation: true}},
  ]) assert.equal(evaluateRestartSafeEligibility(patched, excluded), false, JSON.stringify(excluded));
  assert.equal(patchNativeIOSRestartSafeAdmission(patched), patched);
});

test('projects only authoritative active control-ui recovery state', () => {
  const active = {status: 'running', abortedLastRun: true, restartRecoverySourceIngress: 'control-ui', restartRecoveryDeliverySourceRunId: 'source-1', restartRecoveryDeliveryRunId: 'recovery-1'};
  assert.deepEqual(projectNativeOperatorRecovery(active), {sourceRunId: 'source-1', runId: 'recovery-1'});
  assert.equal(projectNativeOperatorRecovery({...active, status: 'done'}), undefined);
  assert.equal(projectNativeOperatorRecovery({...active, restartRecoverySourceIngress: 'internal'}), undefined);
  assert.equal(projectNativeOperatorRecovery({...active, abortedLastRun: false, restartRecoveryDeliveryRunId: 'source-1'}), undefined);
  assert.deepEqual(projectNativeOperatorRecovery({...active, abortedLastRun: false}), {sourceRunId: 'source-1', runId: 'recovery-1'});
});

test('patches the pinned recovery only after its durable replacement succeeds', () => {
  const result = patchNativeRecoveryRegistration(recoverySource);
  const replacementEnd = result.indexOf('\n\t\tconst agentParams = {');
  const registration = result.indexOf('registerNativeRecoverySourceRun(recoveryRunId, sourceRunId)');
  assert.ok(registration > 0 && registration < replacementEnd);
  assert.match(result, /restartRecoverySourceIngress === "control-ui"/);
  assert.equal(patchNativeRecoveryRegistration(result), result);
});

test('wraps the real pinned transcript attachment without replacing runId behavior', () => {
  const result = patchNativeTranscriptRecoverySource(transcriptSource);
  assert.match(result, /return attachNativeRecoverySourceRunId\(messageWithRunId, normalizedRunId\)/);
  assert.match(result, /runId: normalizedRunId/);
  assert.equal(patchNativeTranscriptRecoverySource(result), result);
});

test('adds operatorRecovery to normal and delta history responses', () => {
  const result = patchNativeChatHistoryRecovery(chatSource);
  assert.match(result, /const operatorRecovery = projectNativeOperatorRecovery\(historyEntry\)/);
  assert.equal(result.split('...operatorRecovery ? { operatorRecovery } : {}').length - 1, 2);
  assert.equal(patchNativeChatHistoryRecovery(result), result);
});

test('patchers fail closed when pinned source shapes drift', () => {
  assert.throws(() => patchNativeRecoveryRegistration(recoverySource.replace('const agentParams = {', 'const changedParams = {')), /Pinned OpenClaw recovery/);
  assert.throws(() => patchNativeTranscriptRecoverySource(transcriptSource.replace('function attachSessionTranscriptRunId(message, runId)', 'function changed(message, runId)')), /Pinned OpenClaw transcript/);
  assert.throws(() => patchNativeChatHistoryRecovery(chatSource.replace('\tconst embeddedRecovery = resolveEmbeddedAgentRunRecoverySnapshot({', '\tconst changedRecovery = resolveEmbeddedAgentRunRecoverySnapshot({')), /Pinned OpenClaw chat history/);
  assert.throws(() => patchNativeIOSRestartSafeAdmission(chatSendSource.replace('turnKind === "main"', 'turnKind === "changed"')), /Pinned OpenClaw chat admission/);
});

test('patchers reject drift in an already-patched source instead of treating it as idempotent', () => {
  const patchedRecovery = patchNativeRecoveryRegistration(recoverySource);
  assert.throws(() => patchNativeRecoveryRegistration(patchedRecovery.replace('const agentParams = {', 'const changedParams = {')), /Pinned OpenClaw recovery/);

  const patchedTranscript = patchNativeTranscriptRecoverySource(transcriptSource);
  assert.throws(() => patchNativeTranscriptRecoverySource(patchedTranscript.replace('function attachSessionTranscriptRunId(message, runId)', 'function changed(message, runId)')), /Pinned OpenClaw transcript/);

  const patchedChat = patchNativeChatHistoryRecovery(chatSource);
  assert.throws(() => patchNativeChatHistoryRecovery(patchedChat.replace('\tconst embeddedRecovery = resolveEmbeddedAgentRunRecoverySnapshot({', '\tconst changedRecovery = resolveEmbeddedAgentRunRecoverySnapshot({')), /Pinned OpenClaw chat history/);

  const patchedChatSend = patchNativeIOSRestartSafeAdmission(chatSendSource);
  assert.throws(() => patchNativeIOSRestartSafeAdmission(patchedChatSend.replace('turnKind === "main"', 'turnKind === "changed"')), /Pinned OpenClaw chat admission/);
});
