import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {patchNativeOwnershipAdmission} from '../compat/sqlite/ownership.mjs';
import {patchNativeGatewayLoopExport} from '../compat/lifecycle/export.mjs';
import {patchNativeLockRuntimeDirectory} from '../compat/locks/runtime-directory.mjs';
import {OPERATOR_WORKSPACE_GUIDANCE} from './workspace-guidance.mjs';

export function stageRuntime(packageRoot, output) {
  packageRoot = fs.realpathSync(packageRoot);
  const metadata = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
  if (metadata.name !== 'openclaw' || metadata.version !== '2026.9.1') throw new Error('Expected the tested OpenClaw 2026.9.1 package');
  if (fs.existsSync(output)) throw new Error('Output already exists; preserve it and choose a new staging directory');
  const modules = fs.readdirSync(path.join(packageRoot, 'dist')).filter(name => /^server-start-[^.]+\.js$/.test(name));
  if (modules.length !== 1) throw new Error('Expected exactly one gateway entry module');
  const ownershipModule = 'dist/openclaw-state-db-Bh3Bq87y.js';
  const patched = patchNativeOwnershipAdmission(fs.readFileSync(path.join(packageRoot, ownershipModule), 'utf8'));
  const lifecycleModule = 'dist/run-CrJnbDWP.js';
  const lifecycle = patchNativeGatewayLoopExport(fs.readFileSync(path.join(packageRoot, lifecycleModule), 'utf8'));
  const locksModule = 'dist/state-database-coordinator-DKD8Uulb.js';
  const locks = patchNativeLockRuntimeDirectory(fs.readFileSync(path.join(packageRoot, locksModule), 'utf8'));
  const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  fs.mkdirSync(output, {recursive: true});
  const copy = (source, target) => fs.cpSync(source, target, {
    recursive: true, verbatimSymlinks: true, mode: fs.constants.COPYFILE_FICLONE,
    filter: file => {
      if (fs.lstatSync(file).isSymbolicLink()) {
        const resolved = fs.realpathSync(file);
        if (!resolved.startsWith(packageRoot + path.sep)) throw new Error('Package symlink escapes the public package');
      }
      return true;
    }
  });
  for (const name of ['dist', 'node_modules', 'package.json', 'LICENSE', 'README.md', 'openclaw.mjs']) {
    const source = path.join(packageRoot, name);
    if (fs.existsSync(source)) copy(source, path.join(output, 'openclaw', name));
  }
  // OpenClaw reads these public files when preparing an agent's workspace.
  // They are runtime inputs even though the upstream package keeps them in docs.
  const templates = path.join(output, 'openclaw/docs/reference/templates');
  copy(path.join(packageRoot, 'docs/reference/templates'), templates);
  // OpenClaw seeds AGENTS.md from this template and only when it is missing, so
  // the template is the only place guidance survives a clean install. Appended
  // to the staged copy, never to the public package.
  const agentsTemplate = path.join(templates, 'AGENTS.md');
  const seeded = fs.readFileSync(agentsTemplate, 'utf8');
  if (seeded.includes('## When you cannot carry something out')) throw new Error('Upstream AGENTS.md template already carries the Operator guidance');
  fs.writeFileSync(agentsTemplate, `${seeded.trimEnd()}\n${OPERATOR_WORKSPACE_GUIDANCE}`);
  for (const name of ['entry.mjs', 'host/start.mjs', 'gateway/state.mjs']) {
    copy(path.join(sourceRoot, name), path.join(output, name));
  }
  fs.writeFileSync(path.join(output, 'openclaw', ownershipModule), patched);
  fs.writeFileSync(path.join(output, 'openclaw', lifecycleModule), lifecycle);
  fs.writeFileSync(path.join(output, 'openclaw', locksModule), locks);
  fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
    openclawVersion: metadata.version, gatewayModule: `dist/${modules[0]}`,
    lifecycleModule, patches: ['native-sqlite-ownership', 'native-gateway-loop-export', 'native-lock-directory']
  }, null, 2));
}
