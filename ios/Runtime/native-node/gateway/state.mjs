import fs from 'node:fs';
import path from 'node:path';
import {randomBytes} from 'node:crypto';
import {OPERATOR_GUIDANCE_END, OPERATOR_GUIDANCE_HEADING, OPERATOR_GUIDANCE_START, OPERATOR_WORKSPACE_GUIDANCE} from '../package/workspace-guidance.mjs';

/// Bring the Operator section of the workspace AGENTS.md up to the current
/// wording. Three shapes are handled: a marked section is replaced in place;
/// a section from before the markers (heading to end of file, which is where
/// staging appended it) is replaced once and gains the markers; a file with
/// neither is left for OpenClaw, which seeds it from the template. Anything
/// outside the section is the owner's and is preserved byte for byte.
export function refreshWorkspaceGuidance(workspace) {
  const file = path.join(workspace, 'AGENTS.md');
  let current;
  try { current = fs.readFileSync(file, 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
  const section = OPERATOR_WORKSPACE_GUIDANCE.trim();
  let next;
  const start = current.indexOf(OPERATOR_GUIDANCE_START);
  const end = current.indexOf(OPERATOR_GUIDANCE_END);
  if (start >= 0 && end > start) {
    next = current.slice(0, start) + section + current.slice(end + OPERATOR_GUIDANCE_END.length);
  } else {
    const legacy = current.indexOf(`\n${OPERATOR_GUIDANCE_HEADING}`);
    if (legacy < 0) return false;
    next = `${current.slice(0, legacy).trimEnd()}\n${section}\n`;
  }
  if (next === current) return false;
  fs.writeFileSync(file, next, {mode: 0o600});
  return true;
}

function hasWorkspaceData(directory) {
  try { return fs.statSync(directory).isDirectory() && fs.readdirSync(directory).length > 0; }
  catch { return false; }
}

function relocateManagedWorkspace(state, configPath) {
  const source = fs.readFileSync(configPath, 'utf8');
  let config;
  try { config = JSON.parse(source); }
  catch { return; }
  const configured = config?.agents?.defaults?.workspace;
  const workspace = path.join(state, 'workspace');
  const managedWorkspace = typeof configured === 'string' && path.isAbsolute(configured) && path.basename(configured) === 'workspace' && path.basename(path.dirname(configured)) === 'openclaw' && path.basename(path.dirname(path.dirname(configured))) === 'Operator';
  if (!managedWorkspace || configured === workspace) return;
  // iOS moves the data container on every install, and the move carries the
  // workspace with it, so the recorded absolute path is stale while the data
  // is already at the new default location. When the old location still has
  // data and the new one has none, copy it across, preserving the old copy
  // until the owner chooses to remove it. When neither has data there is
  // nothing to recover and nobody can restore a directory inside an iOS
  // container, so dropping the key and letting OpenClaw seed a fresh
  // workspace beats refusing to start forever.
  if (!hasWorkspaceData(workspace) && hasWorkspaceData(configured)) {
    fs.cpSync(configured, workspace, {recursive: true, errorOnExist: true, force: false});
  }
  delete config.agents.defaults.workspace;
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2), {mode: 0o600});
}

function addAutomaticFastModeDefault(configPath) {
  let config;
  try { config = JSON.parse(fs.readFileSync(configPath, 'utf8')); }
  catch (error) { if (error instanceof SyntaxError) return; throw error; }
  const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  if (!isObject(config) || (config.agents !== undefined && !isObject(config.agents))) return;
  if (config.agents?.defaults !== undefined && !isObject(config.agents.defaults)) return;
  if (config.agents?.defaults?.fastModeDefault !== undefined) return;
  config.agents ??= {};
  config.agents.defaults ??= {};
  config.agents.defaults.fastModeDefault = 'auto';
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2), {mode: 0o600});
}

// Trim old tool results before each model call. OpenClaw leaves this off
// for non-Anthropic providers, and Operator's context is mostly tool
// results (a Discord pass, a WhatsApp sync), so without it every later
// question carries all of them until compaction. In-memory only; the
// transcript on disk is untouched. An explicit setting, including "off",
// is never replaced.
function addContextPruningDefault(configPath) {
  let config;
  try { config = JSON.parse(fs.readFileSync(configPath, 'utf8')); }
  catch (error) { if (error instanceof SyntaxError) return; throw error; }
  const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  if (!isObject(config) || (config.agents !== undefined && !isObject(config.agents))) return;
  if (config.agents?.defaults !== undefined && !isObject(config.agents.defaults)) return;
  if (config.agents?.defaults?.contextPruning !== undefined) return;
  config.agents ??= {};
  config.agents.defaults ??= {};
  config.agents.defaults.contextPruning = {mode: 'cache-ttl', ttl: '5m'};
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2), {mode: 0o600});
}

function addNativeSearchDefaults(configPath) {
  let config;
  try { config = JSON.parse(fs.readFileSync(configPath, 'utf8')); }
  catch (error) { if (error instanceof SyntaxError) return; throw error; }
  const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  if (!isObject(config)) return;
  let current = config;
  for (const key of ['tools', 'web', 'search', 'openaiCodex']) {
    if (current[key] !== undefined && !isObject(current[key])) return;
    current = current[key] ?? {};
  }
  const search = config.tools?.web?.search;
  // Never replace a chosen provider, disable, mode or search restriction.
  if (search?.enabled === false || search?.provider !== undefined || search?.openaiCodex?.enabled === false) return;
  if (current.enabled !== undefined && current.mode !== undefined) return;
  config.tools ??= {};
  config.tools.web ??= {};
  config.tools.web.search ??= {};
  config.tools.web.search.openaiCodex ??= {};
  const native = config.tools.web.search.openaiCodex;
  if (native.enabled === undefined) native.enabled = true;
  if (native.mode === undefined) native.mode = 'live';
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2), {mode: 0o600});
}

export function prepareState(state) {
  fs.mkdirSync(state, {recursive: true, mode: 0o700});
  const workspace = path.join(state, 'workspace');
  const configPath = path.join(state, 'openclaw.json');
  const config = {
    gateway: {mode: 'local', bind: 'loopback', auth: {mode: 'token', token: randomBytes(32).toString('hex')}, controlUi: {enabled: false}},
    // OpenClaw resolves the default workspace from OPENCLAW_STATE_DIR/workspace.
    // Keeping it out of the file survives an iOS app-container relocation.
    agents: {defaults: {fastModeDefault: 'auto', contextPruning: {mode: 'cache-ttl', ttl: '5m'}}},
    tools: {web: {search: {openaiCodex: {enabled: true, mode: 'live'}}}}
  };
  try {
    // Exclusive creation: reopening must never replace settings or saved sign-in.
    fs.writeFileSync(configPath, JSON.stringify(config), {flag: 'wx', mode: 0o600});
    fs.mkdirSync(workspace, {recursive: true, mode: 0o700});
    return {configPath, created: true};
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    // Only migrate the app's former workspace location after its contents survive.
    // Other JSON5 configuration remains OpenClaw-owned and is left untouched.
    relocateManagedWorkspace(state, configPath);
    // A saved default keeps ordinary chat free of restart-unsafe message overrides.
    // Preserve explicit preferences and leave non-JSON configuration untouched.
    addAutomaticFastModeDefault(configPath);
    addContextPruningDefault(configPath);
    addNativeSearchDefaults(configPath);
    fs.mkdirSync(workspace, {recursive: true, mode: 0o700});
    return {configPath, created: false, guidanceRefreshed: refreshWorkspaceGuidance(workspace)};
  }
}

