import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {prepareState} from './state.mjs';
const directory = process.env.OPERATOR_PROBE_DIRECTORY;
const started = performance.now();
const result = {run: process.env.OPERATOR_PROBE_RUN, platform: process.platform,
  node: process.versions.node, status: 'running', checks: [], gatewayImported: false, gatewayStarted: false};
const save = () => {
  const text = JSON.stringify({...result, elapsedMs: performance.now() - started});
  fs.writeFileSync(path.join(directory, 'openclaw-result.json'), text);
  fs.writeFileSync(path.join(directory, 'result.json'), text);
};
save();
try {
  const state = path.join(directory, 'openclaw-state');
  const prepared = prepareState(state);
  process.env.OPENCLAW_STATE_DIR = state;
  process.env.OPENCLAW_CONFIG_PATH = prepared.configPath;
  result.statePreparation = prepared.created ? 'created' : 'reused';
  save();
  const moduleURL = pathToFileURL(path.join(directory, 'openclaw/dist/server-start-BNcm1gUN.js'));
  const {startGatewayServerCore} = await import(moduleURL.href);
  result.gatewayImported = true;
  result.checks.push('gateway-import');
  save();
  // A separate loopback port keeps this probe apart from the existing test app.
  await startGatewayServerCore(18791, {bind: 'loopback'});
  result.gatewayStarted = true;
  result.checks.push('gateway-start');
  result.status = 'pass';
} catch (error) {
  result.status = 'fail';
  result.error = {name: error.name, message: error.message, code: error.code};
}
save();
