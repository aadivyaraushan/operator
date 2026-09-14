import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {prepareState} from '../gateway/state.mjs';

export async function startEmbeddedRuntime({stateDirectory, runtimeDirectory, gatewayToken, runID, statusPath, requiredGatewayPort}) {
  const started = performance.now();
  let stage = 'state';
  // This small status file is also the native host's startup log. Never include
  // raw upstream errors: they may contain credentials or message text.
  const save = (status, error, diagnostic) => fs.writeFileSync(statusPath, JSON.stringify({
    runID, status, stage, elapsedMs: performance.now() - started,
    ...(error ? {error} : {}), ...(diagnostic ? {diagnostic} : {})
  }), {mode: 0o600});
  try {
    fs.mkdirSync(stateDirectory, {recursive: true, mode: 0o700});
    save('starting');
    if (!gatewayToken || !runID || !Number.isInteger(requiredGatewayPort) || requiredGatewayPort < 1 || requiredGatewayPort > 65535) throw new Error('Missing native startup requirements');
    const prepared = prepareState(stateDirectory);
    process.env.OPENCLAW_STATE_DIR = stateDirectory;
    process.env.OPENCLAW_CONFIG_PATH = prepared.configPath;
    // OpenClaw's lifecycle locks default to /tmp, which an iPhone cannot write.
    // Keep them beside the gateway lock files in the state directory the app owns.
    process.env.OPERATOR_STATE_LOCK_DIR = path.join(stateDirectory, 'locks');
    // Under NodeMobile process.platform is "ios", not "darwin", so OpenClaw
    // roots its cache at ~/.cache -- the container root, which iOS refuses to
    // let the app create files in. XDG_CACHE_HOME is honoured first.
    process.env.XDG_CACHE_HOME = path.join(stateDirectory, 'cache');
    // iOS owns the process. OpenClaw must restart its server in this process.
    process.env.OPENCLAW_NO_RESPAWN = '1';
    process.env.OPENCLAW_GATEWAY_PORT = String(requiredGatewayPort);
    stage = 'gateway-import';
    save('starting');
    const manifest = JSON.parse(fs.readFileSync(path.join(runtimeDirectory, 'manifest.json'), 'utf8'));
    const packageRoot = path.join(runtimeDirectory, 'openclaw');
    const gatewayPath = path.resolve(packageRoot, manifest.gatewayModule);
    const lifecyclePath = path.resolve(packageRoot, manifest.lifecycleModule);
    if (![gatewayPath, lifecyclePath].every(file => file.startsWith(packageRoot + path.sep))) throw new Error('Invalid bundled runtime path');
    const {startGatewayServerCore} = await import(pathToFileURL(gatewayPath).href);
    const {runGatewayLoop} = await import(pathToFileURL(lifecyclePath).href);
    stage = 'gateway-start';
    save('starting');
    await runGatewayLoop({
      ownsProcessLifecycle: false,
      lockPort: requiredGatewayPort,
      runtime: {exit: () => { stage = 'gateway-stopped'; save('failed', 'The local runtime stopped.'); }},
      completeBoot: result => {
        if (result.outcome === 'startup_failed') save('failed', 'The local runtime could not restart.');
      },
      start: async ({processStartedAt, startupStartedAt, requestHotReloadRecovery}) => {
        stage = 'gateway-start';
        save('starting');
        const server = await startGatewayServerCore(requiredGatewayPort, {
          bind: 'loopback', auth: {mode: 'token', token: gatewayToken},
          processStartedAt, startupStartedAt, hotReloadRecovery: requestHotReloadRecovery
        });
        stage = 'gateway-ready';
        save('ready');
        return server;
      }
    });
  } catch (error) {
    // Record only public bundled code locations, never error messages, local
    // paths, or arbitrary error fields that could contain account information.
    let prefix;
    try {
      prefix = pathToFileURL(path.join(fs.realpathSync(runtimeDirectory), 'openclaw/dist')).href + '/';
    } catch {
      // A missing bundle has no bundled stack frames to report.
    }
    const frames = String(error?.stack ?? '').split('\n').slice(1).flatMap(line => {
      if (!prefix) return [];
      const index = line.indexOf(prefix);
      if (index < 0) return [];
      const match = line.slice(index + prefix.length).match(/^([A-Za-z0-9_./-]+\.js:\d+:\d+)\)?$/);
      return match ? [match[1]] : [];
    }).slice(0, 4);
    const name = ['Error', 'TypeError', 'RangeError', 'SyntaxError', 'AbortError'].includes(error?.name) ? error.name : 'Error';
    save('failed', 'The local runtime could not start.', {name, frames});
  }
}
