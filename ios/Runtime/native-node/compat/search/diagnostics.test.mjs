import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {patchNativeSearchDiagnostics} from './diagnostics.mjs';

const original = fs.readFileSync(new URL('../../../../build/native-node/runtime/openclaw/node_modules/@openclaw/ai/dist/openai-chatgpt-responses-BAJ4gq3i.mjs', import.meta.url), 'utf8');
function mapper(source, logs) {
  const start = source.indexOf('async function* mapCodexEvents(events) {');
  const end = source.indexOf('\nfunction normalizeCodexStatus', start);
  assert.ok(start >= 0 && end > start);
  return vm.runInNewContext(source.slice(start, end) + '\nmapCodexEvents', {
    getAiTransportHost: () => ({logInfo: (...args) => logs.push(args)}),
    normalizeCodexStatus: value => value
  });
}

test('real ChatGPT event mapper logs search completion without logging event contents', async () => {
  const logs = [];
  const map = mapper(patchNativeSearchDiagnostics(original), logs);
  const events = [
    {type: 'response.web_search_call.in_progress', query: 'private-query'},
    {type: 'response.web_search_call.completed', item_id: 'private-id', secret: 'private-token'},
    {type: 'response.output_item.done', item: {type: 'web_search_call', status: 'completed', action: {query: 'private-query'}}},
    {type: 'response.output_item.done', item: {type: 'web_search_call', status: 'failed'}},
    {type: 'response.output_item.done', item: {type: 'message', status: 'completed'}},
  ];
  const observed = [];
  for await (const event of map(events)) observed.push(event);
  assert.deepEqual(observed, events);
  assert.equal(logs.length, 2);
  assert.equal(JSON.stringify(logs), JSON.stringify([
    ['openai-transport', '[native-search] provider search completed'],
    ['openai-transport', '[native-search] provider search completed']
  ]));
});

test('search diagnostic patch is repeatable and rejects source drift', () => {
  const patched = patchNativeSearchDiagnostics(original);
  assert.equal(patchNativeSearchDiagnostics(patched), patched);
  assert.throws(() => patchNativeSearchDiagnostics('unrelated code'), /contract/);
  assert.throws(() => patchNativeSearchDiagnostics(original + original), /contract/);
});
