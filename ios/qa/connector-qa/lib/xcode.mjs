import { spawn } from "node:child_process";
import { existsSync, readdirSync, createWriteStream } from "node:fs";
import { join } from "node:path";

export const DERIVED = "/private/tmp/operator-qa-derived";
const COMMON = ["ARCHS=arm64", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "ONLY_ACTIVE_ARCH=YES", "IPHONEOS_DEPLOYMENT_TARGET=18.0"];

function run(cmd, args, { env = {}, logFile, cwd } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    const sink = logFile ? createWriteStream(logFile, { flags: "a" }) : null;
    for (const stream of [child.stdout, child.stderr]) {
      stream.on("data", (d) => { out += d; sink?.write(d); });
    }
    child.on("exit", (code) => { sink?.end(); resolve({ code, out }); });
  });
}

/// Compiles the app plus the QA UI-test bundle for the given Simulator.
/// Signing stays on: an unsigned build cannot read the live Keychain.
export async function buildForTesting({ repoRoot, udid, scheme = "OperatorAppQA", logFile }) {
  const args = ["-project", join(repoRoot, "ios/Operator.xcodeproj"), "-scheme", scheme,
    "-destination", `platform=iOS Simulator,id=${udid}`, "-configuration", "Debug",
    "-derivedDataPath", DERIVED, ...COMMON, "build-for-testing"];
  const { code, out } = await run("xcodebuild", args, { logFile, cwd: repoRoot });
  if (code !== 0) throw new Error(`build-for-testing failed (exit ${code}); see ${logFile}\n${out.split("\n").filter((l) => /error:/.test(l)).slice(0, 10).join("\n")}`);
  return xctestrun(scheme);
}

export function xctestrun(scheme = "OperatorAppQA") {
  const dir = join(DERIVED, "Build/Products");
  if (!existsSync(dir)) return null;
  const file = readdirSync(dir).find((f) => f.startsWith(`${scheme}_`) && f.endsWith(".xctestrun"));
  return file ? join(dir, file) : null;
}

/// Runs the driver on one batch file. Returns the xcodebuild exit code and output.
export async function runBatch({ udid, batchFile, resultBundle, logFile, testrun }) {
  const args = ["test-without-building", "-xctestrun", testrun,
    "-destination", `platform=iOS Simulator,id=${udid}`,
    "-only-testing:OperatorAppUITests/ScenarioDriverUITests/testRunScenarioBatch",
    "-resultBundlePath", resultBundle];
  return run("xcodebuild", args, { logFile, env: { TEST_RUNNER_OPERATOR_QA_BATCH: batchFile, TEST_RUNNER_OPERATOR_QA: "1" } });
}

/// Sweeps every artifact tagged with `marker` from the owner's accounts.
export async function runCleanup({ repoRoot, udid, marker, logFile }) {
  let testrun = xctestrun("OperatorAppLive");
  if (!testrun) testrun = await buildForTesting({ repoRoot, udid, scheme: "OperatorAppLive", logFile });
  const args = ["test-without-building", "-xctestrun", testrun,
    "-destination", `platform=iOS Simulator,id=${udid}`,
    "-only-testing:OperatorAppTests/LiveConnectorCleanupTests"];
  return run("xcodebuild", args, { logFile, env: { TEST_RUNNER_OPERATOR_QA_MARKER: marker, TEST_RUNNER_OPERATOR_LIVE: "1" } });
}
