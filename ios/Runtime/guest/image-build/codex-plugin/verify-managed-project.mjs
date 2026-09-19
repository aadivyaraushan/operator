import { cp, lstat, mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const PLUGIN_NAME = "@openclaw/codex";
const PLUGIN_VERSION = "2026.9.1";
const REQUIRED_DEPENDENCIES = Object.freeze({
  "@openai/codex": "0.152.1",
  semver: "7.8.5",
  "smol-toml": "1.8.0",
  typebox: "1.3.17",
  ws: "8.21.3",
  zod: "4.4.3",
});
const PLATFORM_PACKAGE = "@openai/codex";
const LINUX_PLATFORMS = Object.freeze({
  "codex-linux-x64": { architecture: "x64", triple: "x86_64-unknown-linux-musl" },
  "codex-linux-arm64": { architecture: "arm64", triple: "aarch64-unknown-linux-musl" },
});
const PLUGIN_ARCHIVE_SRI = "sha512-O+HzImle5txYh93pa5CqeFQUA4XHqCpC4bFo7GKrb3WiyPppXtM0JZQ/sVC8E4aeGPGiy3Yx3rI8sl6ceSDH9g==";

function packagePath(projectRoot, packageName) {
  return path.join(projectRoot, "node_modules", ...packageName.split("/"));
}

async function readJson(file) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    throw new Error(`invalid or missing JSON: ${file}`, { cause: error });
  }
}

async function assertDirectory(directory, message) {
  try {
    if ((await lstat(directory)).isDirectory()) return;
  } catch {}
  throw new Error(message);
}

async function assertCleanProjectTree(root) {
  const forbiddenNames = new Set([".npm", ".npmrc", ".cache", "_cacache", "_logs", "auth", "cache", "config", "logs", "state"]);
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const lower = entry.name.toLowerCase();
      const file = path.join(directory, entry.name);
      if (forbiddenNames.has(lower) || lower.endsWith(".sqlite") || lower.endsWith(".sqlite-wal") || lower.endsWith(".sqlite-shm") || lower.endsWith(".db")) {
        throw new Error(`forbidden state artifact in shipped project: ${file}`);
      }
      if (entry.isDirectory()) await visit(file);
    }
  }
  await visit(root);
}

async function assertPinnedRegistryInstall(projectRoot, dependencySpec) {
  if (dependencySpec !== PLUGIN_VERSION) {
    throw new Error(`managed project must use the exact official npm dependency ${PLUGIN_NAME}@${PLUGIN_VERSION}`);
  }
  const lock = await readJson(path.join(projectRoot, "package-lock.json"));
  const entry = lock.packages?.[`node_modules/${PLUGIN_NAME}`];
  if (entry?.version !== PLUGIN_VERSION || entry.integrity !== PLUGIN_ARCHIVE_SRI) {
    throw new Error(`package-lock integrity does not match ${PLUGIN_NAME}@${PLUGIN_VERSION}`);
  }
  if (entry.resolved !== `https://registry.npmjs.org/@openclaw/codex/-/codex-${PLUGIN_VERSION}.tgz`) {
    throw new Error(`package-lock does not resolve ${PLUGIN_NAME} from the official npm registry`);
  }
}

async function loadPinnedRecoveryReader(openclawRoot) {
  if (!openclawRoot) throw new Error("openclawRoot is required to prove managed-project recovery");
  const reader = path.join(openclawRoot, "dist", "installed-plugin-index-record-reader-CGCFpTaD.js");
  const { r: loadInstalledPluginIndexInstallRecords } = await import(pathToFileURL(reader).href);
  if (typeof loadInstalledPluginIndexInstallRecords !== "function") throw new Error("pinned installed-plugin-index reader export is unavailable");
  return loadInstalledPluginIndexInstallRecords;
}

async function loadPinnedOfficialTrustPredicate(openclawRoot) {
  const modulePath = path.join(openclawRoot, "dist", "official-external-install-records-C9CpHadm.js");
  const { i: isTrustedOfficialPluginInstallRecord } = await import(pathToFileURL(modulePath).href);
  if (typeof isTrustedOfficialPluginInstallRecord !== "function") {
    throw new Error("pinned official-install trust predicate export is unavailable");
  }
  return isTrustedOfficialPluginInstallRecord;
}

async function verifyManagedProject({ projectRoot, openclawRoot }) {
  await assertDirectory(projectRoot, `managed project is missing: ${projectRoot}`);
  await assertCleanProjectTree(projectRoot);

  const projectPackage = await readJson(path.join(projectRoot, "package.json"));
  await assertPinnedRegistryInstall(projectRoot, projectPackage.dependencies?.[PLUGIN_NAME]);
  const pluginRoot = packagePath(projectRoot, PLUGIN_NAME);
  const pluginPackage = await readJson(path.join(pluginRoot, "package.json"));
  if (pluginPackage.name !== PLUGIN_NAME || pluginPackage.version !== PLUGIN_VERSION) {
    throw new Error(`managed project must contain ${PLUGIN_NAME}@${PLUGIN_VERSION}`);
  }
  for (const [name, version] of Object.entries(REQUIRED_DEPENDENCIES)) {
    if (pluginPackage.dependencies?.[name] !== version) throw new Error(`plugin package must declare ${name}@${version}`);
    const dependency = await readJson(path.join(packagePath(projectRoot, name), "package.json"));
    if (dependency.name !== name || dependency.version !== version) throw new Error(`managed project must contain ${name}@${version}`);
  }
  // Inspect the shipped target, not the build Mac's architecture. Reject mixed
  // packages before trusting a binary path or recovering official provenance.
  const platformEntries = (await readdir(path.join(projectRoot, "node_modules", "@openai"), { withFileTypes: true }))
    .filter((entry) => entry.name.startsWith("codex-"));
  const platformEntry = platformEntries[0];
  const platform = LINUX_PLATFORMS[platformEntry?.name];
  if (platformEntries.length !== 1 || !platformEntry.isDirectory() || !platform) {
    throw new Error("managed project must ship exactly one supported Linux Codex platform package");
  }
  const platformDirectory = platformEntry.name;
  const platformVersion = `${REQUIRED_DEPENDENCIES[PLATFORM_PACKAGE]}-linux-${platform.architecture}`;
  const platformRoot = path.join(projectRoot, "node_modules", "@openai", platformDirectory);
  const platformPackage = await readJson(path.join(platformRoot, "package.json"));
  if (platformPackage.name !== PLATFORM_PACKAGE || platformPackage.version !== platformVersion) {
    throw new Error(`managed project must contain ${PLATFORM_PACKAGE}@${platformVersion}`);
  }
  const binary = path.join(platformRoot, "vendor", platform.triple, "bin", "codex");
  const binaryStat = await lstat(binary).catch(() => undefined);
  if (!binaryStat?.isFile() || (binaryStat.mode & 0o111) === 0) throw new Error(`missing executable Linux ${platform.architecture} Codex binary: ${binary}`);

  const temporaryState = await mkdtemp(path.join(os.tmpdir(), "openclaw-managed-project-state-"));
  try {
    const isolatedProject = path.join(temporaryState, "npm", "projects", "codex");
    await cp(projectRoot, isolatedProject, { recursive: true });
    const loadInstalledPluginIndexInstallRecords = await loadPinnedRecoveryReader(openclawRoot);
    const records = await loadInstalledPluginIndexInstallRecords({ stateDir: temporaryState });
    const record = records.codex;
    if (record?.source !== "npm" || record.resolvedName !== PLUGIN_NAME || record.resolvedVersion !== PLUGIN_VERSION) {
      throw new Error("pinned installed-plugin-index reader did not recover codex from the isolated managed project");
    }
    const isTrustedOfficialPluginInstallRecord = await loadPinnedOfficialTrustPredicate(openclawRoot);
    const trustedOfficialInstall = isTrustedOfficialPluginInstallRecord({
      pluginId: "codex",
      packageName: PLUGIN_NAME,
      record,
    });
    if (!trustedOfficialInstall) throw new Error("managed project does not recover trusted official npm provenance");
    return Object.freeze({
      record: Object.freeze({ id: "codex", version: record.resolvedVersion, ...record }),
      platformPackage: `@openai/${platformDirectory} (${PLATFORM_PACKAGE}@${platformVersion})`,
      trustedOfficialInstall,
      offline: true,
      scope: "metadata recovery via the pinned installed-plugin-index reader; it does not launch the Linux Codex binary",
    });
  } finally {
    await rm(temporaryState, { recursive: true, force: true });
  }
}

export { verifyManagedProject };

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argumentsByName = new Map();
  for (let index = 2; index < process.argv.length; index += 2) argumentsByName.set(process.argv[index], process.argv[index + 1]);
  const result = await verifyManagedProject({
    projectRoot: argumentsByName.get("--project-root"),
    openclawRoot: argumentsByName.get("--openclaw-root"),
  });
  console.log(JSON.stringify(result));
}
