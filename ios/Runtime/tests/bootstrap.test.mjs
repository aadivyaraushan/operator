import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

// bootstrap.sh resolves every output path from its own location, so these
// tests run a copy of it from a throwaway tree. Nothing here can reach the
// real ios/build directory, which matters because one of the behaviours
// under test is what the script does when an output already exists.
//
// Anything needing Xcode is out of scope by construction: --check and --pin
// are the two modes that work without it, and they are the two the next
// developer runs first.

const here = path.dirname(fileURLToPath(import.meta.url));
const realScript = path.resolve(here, "../bootstrap.sh");

function sandbox() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "operator-bootstrap-test-"));
  fs.mkdirSync(path.join(root, "ios/Runtime"), { recursive: true });
  const script = path.join(root, "ios/Runtime/bootstrap.sh");
  fs.copyFileSync(realScript, script);
  fs.chmodSync(script, 0o755);
  return { root, script, build: path.join(root, "ios/build") };
}

function run(script, args) {
  try {
    return { code: 0, out: execFileSync("sh", [script, ...args], { encoding: "utf8", stdio: "pipe" }) };
  } catch (error) {
    return { code: error.status, out: (error.stdout ?? "") + (error.stderr ?? "") };
  }
}

function framework(root, name = "NodeMobile.xcframework") {
  const dir = path.join(root, name);
  fs.mkdirSync(path.join(dir, "ios-arm64"), { recursive: true });
  fs.writeFileSync(path.join(dir, "ios-arm64/libNode.a"), "not really a binary");
  fs.writeFileSync(path.join(dir, "Info.plist"), "<plist/>");
  return dir;
}

function openclaw(root, { version = "2026.9.1", modules = true, dist = true } = {}) {
  const dir = path.join(root, "openclaw");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({ name: "openclaw", version }));
  if (modules) fs.mkdirSync(path.join(dir, "node_modules"), { recursive: true });
  if (dist) fs.mkdirSync(path.join(dir, "dist"), { recursive: true });
  return dir;
}

function wacli(root, { goMod = true } = {}) {
  const dir = path.join(root, "wacli");
  fs.mkdirSync(dir, { recursive: true });
  if (goMod) fs.writeFileSync(path.join(dir, "go.mod"), "module github.com/openclaw/wacli\ngo 1.26.6\n");
  return dir;
}

test("a wrong argument count is a usage error, not a partial run", () => {
  const { script } = sandbox();
  for (const args of [[], ["one"], ["one", "two"], ["--pin"], ["--pin", "a", "b"]]) {
    const result = run(script, args);
    assert.equal(result.code, 64, `args=${JSON.stringify(args)}`);
    assert.match(result.out, /usage: bootstrap\.sh/);
  }
});

test("--pin reports a checksum and writes nothing", () => {
  const { script, root, build } = sandbox();
  const result = run(script, ["--pin", framework(root)]);
  assert.equal(result.code, 0);
  assert.match(result.out, /nodemobile_sha256=[0-9a-f]{64}/);
  assert.match(result.out, /BOOTSTRAP_PIN_PASS/);
  assert.equal(fs.existsSync(build), false, "--pin must not create outputs");
});

test("--pin gives the same checksum for the archive and the extracted directory", () => {
  const { script, root } = sandbox();
  const dir = framework(root);
  execFileSync("zip", ["-qr", path.join(root, "framework.zip"), "NodeMobile.xcframework"], { cwd: root });

  const fromDir = run(script, ["--pin", dir]).out.match(/nodemobile_sha256=([0-9a-f]{64})/)[1];
  const fromZip = run(script, ["--pin", path.join(root, "framework.zip")]).out.match(/nodemobile_sha256=([0-9a-f]{64})/)[1];

  // The release ships a .zip and the handoff tells people to extract it. If
  // those two routes disagreed, the pin would depend on which one someone
  // happened to take.
  assert.equal(fromDir, fromZip);
});

test("--pin refuses a path with no framework in it", () => {
  const { script, root } = sandbox();
  fs.mkdirSync(path.join(root, "empty"));
  const result = run(script, ["--pin", path.join(root, "empty")]);
  assert.equal(result.code, 66);
  assert.match(result.out, /no NodeMobile\.xcframework/);
});

test("--pin accepts the directory the archive was extracted into", () => {
  const { script, root } = sandbox();
  const parent = path.join(root, "extracted");
  fs.mkdirSync(parent, { recursive: true });
  framework(parent);
  const result = run(script, ["--pin", parent]);
  assert.equal(result.code, 0);
  assert.match(result.out, /nodemobile_sha256=[0-9a-f]{64}/);
});

test("--pin refuses a directory that only has the right name", () => {
  const { script, root } = sandbox();
  const empty = path.join(root, "NodeMobile.xcframework");
  fs.mkdirSync(empty, { recursive: true });
  const result = run(script, ["--pin", empty]);
  assert.equal(result.code, 66, "an xcframework without an Info.plist is not an xcframework");
});

test("--check names every input problem rather than stopping at the first", () => {
  const { script, root } = sandbox();
  const result = run(script, [
    "--check",
    path.join(root, "absent-framework"),
    openclaw(root, { version: "2026.8.0", modules: false }),
    wacli(root, { goMod: false }),
  ]);
  assert.match(result.out, /NodeMobile\s+MISSING/);
  assert.match(result.out, /version 2026\.8\.0 does not match the pinned 2026\.9\.1/);
  assert.match(result.out, /node_modules is absent/);
  assert.match(result.out, /MISSING go\.mod/);
  assert.match(result.out, /BOOTSTRAP_CHECK_INCOMPLETE/);
});

test("--check accepts a well-formed input set", () => {
  const { script, root } = sandbox();
  const result = run(script, ["--check", framework(root), openclaw(root), wacli(root)]);
  // The toolchain half depends on the machine - a Command Line Tools box has
  // no iOS SDK and will report INCOMPLETE for that reason alone. What must
  // hold everywhere is that none of the inputs is faulted.
  assert.doesNotMatch(result.out, /NodeMobile\s+MISSING/);
  assert.doesNotMatch(result.out, /does not match the pinned/);
  assert.doesNotMatch(result.out, /node_modules is absent/);
  assert.doesNotMatch(result.out, /MISSING go\.mod/);
  assert.match(result.out, /iOS SDK/);
});

test("--check reports outputs that already exist without touching them", () => {
  const { script, root, build } = sandbox();
  const existing = path.join(build, "native-node/runtime");
  fs.mkdirSync(existing, { recursive: true });
  fs.writeFileSync(path.join(existing, "marker"), "keep me");

  const result = run(script, ["--check", framework(root), openclaw(root), wacli(root)]);

  assert.match(result.out, /present\s+.*native-node\/runtime/);
  assert.equal(fs.readFileSync(path.join(existing, "marker"), "utf8"), "keep me");
});

test("a real run refuses to replace an existing output", () => {
  const { script, root, build } = sandbox();
  const existing = path.join(build, "native-whatsapp");
  fs.mkdirSync(existing, { recursive: true });
  fs.writeFileSync(path.join(existing, "libWacliBridge.a"), "hours of build time");

  const result = run(script, [framework(root), openclaw(root), wacli(root)]);

  assert.equal(result.code, 73);
  assert.match(result.out, /refusing to replace an existing output/);
  // The point of refusing is that the thing survives.
  assert.equal(fs.readFileSync(path.join(existing, "libWacliBridge.a"), "utf8"), "hours of build time");
});
