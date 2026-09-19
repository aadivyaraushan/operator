import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
const started = performance.now();
const result = {run: process.env.OPERATOR_PROBE_RUN, platform: process.platform,
  node: process.versions.node, checks: [], status: 'running'};
const output = path.join(process.env.OPERATOR_PROBE_DIRECTORY, 'result.json');
const save = () => fs.writeFileSync(output, JSON.stringify({...result, elapsedMs: performance.now() - started}));
save();
try {
  const assert = (await import('node:assert/strict')).default;
  result.checks.push('esm');
  const {DatabaseSync} = await import('node:sqlite');
  const database = new DatabaseSync(':memory:');
  result.sqlite = database.prepare('SELECT sqlite_version() AS version').get().version;
  assert.equal(database.prepare('SELECT 6 * 7 AS answer').get().answer, 42);
  database.close();
  result.checks.push('sqlite');
  const file = path.join(process.env.OPERATOR_PROBE_DIRECTORY, 'file-check.txt');
  fs.writeFileSync(file, result.run);
  assert.equal(fs.readFileSync(file, 'utf8'), result.run);
  fs.unlinkSync(file);
  result.checks.push('filesystem');
  const server = http.createServer((request, response) => response.end('operator-local-network'));
  await new Promise((resolve, reject) => {server.once('error', reject); server.listen(0, '127.0.0.1', resolve);});
  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}`, {signal: AbortSignal.timeout(10000)});
    assert.equal(await response.text(), 'operator-local-network');
  } finally {await new Promise(resolve => server.close(resolve));}
  result.checks.push('http-fetch');
  result.status = 'pass';
} catch (error) {
  result.status = 'fail';
  result.error = {name: error.name, message: error.message};
}
save();
// Keep the test host alive; returning from Node must not close the iOS UI.
setInterval(() => {}, 60000);
if (result.status === 'pass') await import('./bootstrap.mjs');
