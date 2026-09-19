// Use OpenClaw's public pairing API; never rewrite its state database ourselves.
const expectedDeviceID = process.env.OPENCLAW_EXPECTED_DEVICE_ID;
const expectedPublicKey = process.env.OPENCLAW_EXPECTED_PUBLIC_KEY;
const parentPID = Number(process.env.OPENCLAW_GATEWAY_PARENT_PID);
if (!expectedDeviceID || !expectedPublicKey || !Number.isSafeInteger(parentPID) || parentPID <= 0) {
  console.error('[pairing] missing or invalid launch identity');
  process.exit(64);
}
for (const [signal, code] of [['SIGHUP', 129], ['SIGINT', 130], ['SIGTERM', 143]]) {
  process.on(signal, () => {
    console.error('[pairing] stopping on ' + signal);
    process.exit(code);
  });
}
const { listDevicePairing, approveDevicePairing } = await import(
  'file:///usr/local/lib/node_modules/openclaw/dist/plugin-sdk/device-bootstrap.js'
);
const allowedRoles = ['operator', 'node'];
const rolesOf = value => [...new Set([value.role, ...(Array.isArray(value.roles) ? value.roles : [])].filter(Boolean))];
const exact = value => value && value.deviceId === expectedDeviceID && value.publicKey === expectedPublicKey;
const sleep = () => new Promise(resolve => setTimeout(resolve, 1000));
for (let attempt = 0; attempt < 300; attempt++) {
  try { process.kill(parentPID, 0); } catch { break; }
  try {
    const { pending, paired } = await listDevicePairing();
    if (!Array.isArray(pending) || !Array.isArray(paired)) throw new Error('invalid pairing list');
    const matches = pending.filter(exact);
    if (matches.length > 1) throw new Error('ambiguous requests for injected identity');
    if (matches.length === 1) {
      const request = matches[0];
      const roles = rolesOf(request);
      if (!roles.length || roles.some(role => !allowedRoles.includes(role)) ||
          typeof request.requestId !== 'string' || !request.requestId) {
        throw new Error('invalid requested roles or request ID');
      }
      // Upstream refresh retains identity; replacement generates a new request ID.
      // A disappeared request returns null and is retried, never replaced with --latest.
      const approved = await approveDevicePairing(request.requestId, { callerScopes: ['operator.admin'] });
      if (approved && (approved.status !== 'approved' || !exact(approved.device) ||
          !roles.every(role => rolesOf(approved.device).includes(role)))) {
        throw new Error('approval rejected or returned unexpected identity/roles');
      }
      if (approved) console.error('[pairing] exact app request approved; checking remaining roles');
    } else {
      const devices = paired.filter(exact);
      if (devices.length === 1 && allowedRoles.every(role => rolesOf(devices[0]).includes(role))) {
        console.error('[pairing] app chat and phone-control roles are approved');
        process.exit(0);
      }
    }
    // Re-read after approval; do not infer that an approval alone completed both roles.
    const next = await listDevicePairing();
    if (!Array.isArray(next.pending) || !Array.isArray(next.paired)) throw new Error('invalid pairing list');
    const devices = next.paired.filter(exact);
    if (!next.pending.some(exact) && devices.length === 1 &&
        allowedRoles.every(role => rolesOf(devices[0]).includes(role))) {
      console.error('[pairing] app chat and phone-control roles are approved');
      process.exit(0);
    }
  } catch (error) {
    console.error('[pairing] check failed: ' + (error?.message ?? String(error)));
  }
  await sleep();
}
console.error('[pairing] Gateway exited or startup window ended');
process.exit(75);
