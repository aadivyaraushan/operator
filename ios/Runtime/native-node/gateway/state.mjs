import fs from 'node:fs';
import path from 'node:path';
import {randomBytes} from 'node:crypto';

export function prepareState(state) {
  fs.mkdirSync(state, {recursive: true, mode: 0o700});
  const workspace = path.join(state, 'workspace');
  fs.mkdirSync(workspace, {recursive: true, mode: 0o700});
  const configPath = path.join(state, 'openclaw.json');
  const config = {
    gateway: {mode: 'local', bind: 'loopback', auth: {mode: 'token', token: randomBytes(32).toString('hex')}, controlUi: {enabled: false}},
    agents: {defaults: {workspace}}
  };
  try {
    // Exclusive creation: reopening must never replace settings or saved sign-in.
    fs.writeFileSync(configPath, JSON.stringify(config), {flag: 'wx', mode: 0o600});
    return {configPath, created: true};
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    // OpenClaw owns parsing and validating existing configuration, including JSON5.
    return {configPath, created: false, workspaceRepointed: repointVanishedWorkspace(configPath, workspace)};
  }
}

// iOS gives the app a new data container on every install, so the absolute
// workspace path OpenClaw stored at first launch stops existing and every turn
// fails with WorkspaceVanishedError. Repoint that one key, and only when the
// recorded directory is really gone; anything else in the file, and any file
// that is not plain JSON, is left exactly as OpenClaw wrote it.
function repointVanishedWorkspace(configPath, workspace) {
  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch {
    return false;
  }
  const recorded = config?.agents?.defaults?.workspace;
  if (typeof recorded !== 'string' || recorded === workspace || fs.existsSync(recorded)) return false;
  config.agents.defaults.workspace = workspace;
  const staged = `${configPath}.repoint`;
  fs.writeFileSync(staged, JSON.stringify(config, null, 2), {mode: 0o600});
  fs.renameSync(staged, configPath);
  return true;
}
