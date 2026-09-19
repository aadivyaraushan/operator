import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const testDir = path.dirname(fileURLToPath(import.meta.url));
const runtimeDir = path.resolve(testDir, "..");
const manifest = await readFile(path.join(runtimeDir, "guest/definition/manifest.env"), "utf8");
const archiveName = /^OPENCLAW_RUNTIME_ARCHIVE=(.+)$/m.exec(manifest)?.[1];
assert.ok(archiveName, "guest manifest must name the OpenClaw runtime archive");
const runtimeArchive =
  process.env.OPERATOR_TEST_RUNTIME_ARCHIVE ?? path.join("/private/tmp", archiveName);

const requiredTemplateFiles = [
  "AGENTS.dev.md",
  "AGENTS.md",
  "BOOT.md",
  "BOOTSTRAP.md",
  "CLAUDE.md",
  "HEARTBEAT.md",
  "IDENTITY.dev.md",
  "IDENTITY.md",
  "SOUL.dev.md",
  "SOUL.md",
  "TOOLS.md",
  "USER.dev.md",
  "USER.md",
];

test("the packaged runtime seeds a fresh workspace from its bundled templates", async () => {
  await stat(runtimeArchive);
  const temporaryRoot = await mkdtemp(path.join(os.tmpdir(), "operator-runtime-templates-"));
  const priorStateDir = process.env.OPENCLAW_STATE_DIR;
  try {
    const extractedRoot = path.join(temporaryRoot, "runtime");
    await mkdir(extractedRoot);
    await run("tar", ["-xzf", runtimeArchive, "-C", extractedRoot], { cwd: temporaryRoot });

    const packageRoot = path.join(extractedRoot, "usr/local/lib/node_modules/openclaw");

    process.env.OPENCLAW_STATE_DIR = path.join(temporaryRoot, "state");
    // `workspace-BFk42BX6.js` is the pinned 2026.9.1 test fixture module.
    const workspaceModule = await import(
      pathToFileURL(path.join(packageRoot, "dist/workspace-BFk42BX6.js")).href,
    );
    const workspaceDir = path.join(temporaryRoot, "workspace");
    const result = await workspaceModule.p({ dir: workspaceDir, ensureBootstrapFiles: true });

    assert.equal(result.dir, workspaceDir);
    const templateDir = path.join(packageRoot, "docs/reference/templates");
    assert.deepEqual((await readdir(templateDir)).sort(), requiredTemplateFiles);
    for (const name of ["AGENTS.md", "SOUL.md", "IDENTITY.md", "USER.md", "BOOTSTRAP.md"]) {
      assert.ok((await readFile(path.join(workspaceDir, name), "utf8")).trim(), `${name} was seeded`);
    }
  } finally {
    if (priorStateDir === undefined) {
      delete process.env.OPENCLAW_STATE_DIR;
    } else {
      process.env.OPENCLAW_STATE_DIR = priorStateDir;
    }
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});
