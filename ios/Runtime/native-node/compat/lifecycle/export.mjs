// Expose the pinned upstream owner of gateway shutdown, drain, and restart.
// The iOS host must supply a non-process-exiting runtime and set
// OPENCLAW_NO_RESPAWN=1 before invoking it with ownsProcessLifecycle:false.
export function patchNativeGatewayLoopExport(source) {
  const original = 'export { runGatewayCommand };';
  const exposed = 'export { runGatewayCommand, runGatewayLoop };';
  const count = value => source.split(value).length - 1;
  const contract = [
    'async function runGatewayLoop(params)',
    'params.ownsProcessLifecycle === true',
    'params.runtime.exit(code)',
    'requestHotReloadRecovery: eagerLifecycleRuntime.requestGatewayRestartWithSignalAdmission',
  ];
  if (contract.some(value => count(value) !== 1) || count(original) + count(exposed) !== 1) {
    throw new Error('[operator-native/lifecycle] Pinned OpenClaw lifecycle changed; expected one gateway loop, safe exit hook, recovery callback, and export');
  }
  return source.replace(original, exposed);
}
