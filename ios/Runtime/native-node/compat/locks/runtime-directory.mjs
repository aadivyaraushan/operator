// Applied only while packaging the pinned native iOS OpenClaw distribution.
//
// OpenClaw keeps its gateway-lifecycle lock database under a hardcoded /tmp on
// every non-Windows platform. The iOS Simulator gets away with that because
// its /tmp is the Mac's; a real iPhone cannot write outside its own container,
// so mkdir fails and the gateway dies at startup with "failed to acquire
// gateway state ownership". Let the host name the directory instead. Upstream
// behaviour is unchanged whenever the variable is unset.
export const NATIVE_LOCK_DIRECTORY_VARIABLE = 'OPERATOR_STATE_LOCK_DIR';

export function patchNativeLockRuntimeDirectory(source) {
  const marker = '// Operator native lock directory: /tmp is outside the iOS app sandbox.';
  if (source.includes(marker)) return source;
  const before = 'function resolveStateLifecycleRuntimeDirectory() {\n\treturn process.platform === "win32" ? path.join(os.homedir(), "AppData", "Local", "OpenClaw", "locks") : "/tmp";\n}';
  const after = `function resolveStateLifecycleRuntimeDirectory() {
\t${marker}
\tif (process.env.${NATIVE_LOCK_DIRECTORY_VARIABLE}) return process.env.${NATIVE_LOCK_DIRECTORY_VARIABLE};
\treturn process.platform === "win32" ? path.join(os.homedir(), "AppData", "Local", "OpenClaw", "locks") : "/tmp";
}`;
  const count = value => source.split(value).length - 1;
  // Every lifecycle coordinator must still resolve through this one function,
  // or the patch would move some locks and leave others in /tmp.
  const contract = [
    'params.runtimeDirectory ?? resolveStateLifecycleRuntimeDirectory()',
    'export { resolveStateLifecycleRuntimeDirectory as a,',
  ];
  if (count(before) !== 1 || contract.some(value => count(value) !== 1)) {
    throw new Error('[operator-native/locks] Pinned OpenClaw source changed: expected one /tmp lock-directory resolver used by every lifecycle coordinator');
  }
  return source.replace(before, after);
}
