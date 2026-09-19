import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile, chmod } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { verifyManagedProject } from "./verify-managed-project.mjs";

const expectedDependencies = {
  "@openai/codex": "0.152.1",
  semver: "7.8.5",
  "smol-toml": "1.8.0",
  typebox: "1.3.17",
  ws: "8.21.3",
  zod: "4.4.3",
};
const pluginIntegrity = "sha512-O+HzImle5txYh93pa5CqeFQUA4XHqCpC4bFo7GKrb3WiyPppXtM0JZQ/sVC8E4aeGPGiy3Yx3rI8sl6ceSDH9g==";

const officialTrustModule = path.join(
  process.env.OPENCLAW_ROOT,
  "dist",
  "official-external-install-records-C9CpHadm.js",
);
const { i: isTrustedOfficialPluginInstallRecord } = await import(pathToFileURL(officialTrustModule).href);
assert.equal(isTrustedOfficialPluginInstallRecord({
  pluginId: "codex",
  packageName: "@openclaw/codex",
  record: {
    source: "npm",
    spec: "@untrusted/codex@2026.9.1",
    resolvedName: "@untrusted/codex",
    resolvedSpec: "@untrusted/codex@2026.9.1",
  },
}), false);

async function writeJson(file, value) {
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(value)}\n`);
}

async function makeProject(root, {
  omit = undefined,
  addForbidden = false,
  omitArchive = false,
  dependencySpec = "2026.9.1",
  architecture = "x64",
} = {}) {
  const project = path.join(root, "project");
  const plugin = path.join(project, "node_modules", "@openclaw", "codex");
  const dependencies = { ...expectedDependencies };
  if (omit) delete dependencies[omit];
  await writeJson(path.join(project, "package.json"), {
    name: "openclaw-managed-codex",
    dependencies: { "@openclaw/codex": dependencySpec },
  });
  if (!omitArchive) await writeJson(path.join(project, "package-lock.json"), {
    packages: {
      "node_modules/@openclaw/codex": {
        version: "2026.9.1",
        resolved: "https://registry.npmjs.org/@openclaw/codex/-/codex-2026.9.1.tgz",
        integrity: pluginIntegrity,
      },
    },
  });
  await writeJson(path.join(plugin, "package.json"), {
    name: "@openclaw/codex",
    version: "2026.9.1",
    dependencies,
    openclaw: { extensions: ["./dist/index.js"] },
  });
  await writeJson(path.join(plugin, "openclaw.plugin.json"), { id: "codex" });
  for (const [name, version] of Object.entries(dependencies)) {
    await writeJson(path.join(project, "node_modules", ...name.split("/"), "package.json"), { name, version });
  }
  const linuxPackage = path.join(project, "node_modules", "@openai", `codex-linux-${architecture}`);
  await writeJson(path.join(linuxPackage, "package.json"), {
    name: "@openai/codex",
    version: `0.152.1-linux-${architecture}`,
  });
  const triple = architecture === "arm64" ? "aarch64-unknown-linux-musl" : "x86_64-unknown-linux-musl";
  const binary = path.join(linuxPackage, "vendor", triple, "bin", "codex");
  await mkdir(path.dirname(binary), { recursive: true });
  await writeFile(binary, "#!/bin/sh\nexit 0\n");
  await chmod(binary, 0o755);
  if (addForbidden) await writeFile(path.join(project, "openclaw-state.sqlite"), "not a database");
  return project;
}

const temporary = await mkdtemp(path.join(os.tmpdir(), "managed-codex-verifier-"));
try {
  const missing = path.join(temporary, "missing");
  await assert.rejects(
    verifyManagedProject({ projectRoot: missing, openclawRoot: process.env.OPENCLAW_ROOT }),
    /managed project is missing/,
  );

  const incomplete = await makeProject(path.join(temporary, "incomplete"), { omit: "zod" });
  await assert.rejects(
    verifyManagedProject({ projectRoot: incomplete, openclawRoot: process.env.OPENCLAW_ROOT }),
    /zod@4\.4\.3/,
  );

  const forbidden = await makeProject(path.join(temporary, "forbidden"), { addForbidden: true });
  await assert.rejects(
    verifyManagedProject({ projectRoot: forbidden, openclawRoot: process.env.OPENCLAW_ROOT }),
    /forbidden state artifact/,
  );

  const noArchive = await makeProject(path.join(temporary, "no-archive"), { omitArchive: true });
  await assert.rejects(
    verifyManagedProject({ projectRoot: noArchive, openclawRoot: process.env.OPENCLAW_ROOT }),
    /package-lock\.json/,
  );

  const mismatchedProvenance = await makeProject(path.join(temporary, "mismatched-provenance"), {
    dependencySpec: "2026.9.0",
  });
  await assert.rejects(
    verifyManagedProject({ projectRoot: mismatchedProvenance, openclawRoot: process.env.OPENCLAW_ROOT }),
    /exact official npm dependency/,
  );

  const complete = await makeProject(path.join(temporary, "complete"));
  const result = await verifyManagedProject({ projectRoot: complete, openclawRoot: process.env.OPENCLAW_ROOT });
  assert.equal(result.record.id, "codex");
  assert.equal(result.record.version, "2026.9.1");
  assert.equal(result.record.source, "npm");
  assert.equal(result.record.resolvedName, "@openclaw/codex");
  assert.equal(result.trustedOfficialInstall, true);
  assert.equal(result.platformPackage, "@openai/codex-linux-x64 (@openai/codex@0.152.1-linux-x64)");
  assert.equal(result.offline, true);
  const arm = await makeProject(path.join(temporary, "arm"), { architecture: "arm64" });
  const armResult = await verifyManagedProject({ projectRoot: arm, openclawRoot: process.env.OPENCLAW_ROOT });
  assert.equal(armResult.platformPackage, "@openai/codex-linux-arm64 (@openai/codex@0.152.1-linux-arm64)");
  assert.equal(armResult.trustedOfficialInstall, true);
  await mkdir(path.join(arm, "node_modules", "@openai", "codex-linux-x64"));
  await assert.rejects(verifyManagedProject({ projectRoot: arm, openclawRoot: process.env.OPENCLAW_ROOT }), /exactly one supported Linux Codex platform/);
  const unsupported = await makeProject(path.join(temporary, "unsupported"), { architecture: "riscv64" });
  await assert.rejects(verifyManagedProject({ projectRoot: unsupported, openclawRoot: process.env.OPENCLAW_ROOT }), /exactly one supported Linux Codex platform/);
  const noArmBinary = await makeProject(path.join(temporary, "no-arm-binary"), { architecture: "arm64" });
  await rm(path.join(noArmBinary, "node_modules", "@openai", "codex-linux-arm64", "vendor", "aarch64-unknown-linux-musl", "bin", "codex"));
  await assert.rejects(verifyManagedProject({ projectRoot: noArmBinary, openclawRoot: process.env.OPENCLAW_ROOT }), /missing executable Linux arm64 Codex binary/);
  console.log("PASS managed project recovery, dependency, Linux binary, and clean-tree checks");
} finally {
  await rm(temporary, { recursive: true, force: true });
}
