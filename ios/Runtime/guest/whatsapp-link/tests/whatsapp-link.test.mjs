import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  LinkAccessError,
  createWacliProcess,
  WacliPhoneLinkService,
  registerWhatsAppLinkGatewayMethods,
} from "../plugin/runtime/service.js";

const packageManifest = JSON.parse(readFileSync(new URL("../plugin/package.json", import.meta.url)));
const pluginManifest = JSON.parse(readFileSync(new URL("../plugin/openclaw.plugin.json", import.meta.url)));

const CLIENT = {
  connect: {
    client: { id: "openclaw-ios", instanceId: "first-installation" },
    device: { id: "iphone-device-a" },
    role: "operator",
    scopes: ["operator.admin", "operator.read", "operator.write"],
  },
  pairedClientId: "openclaw-ios",
};

function client(overrides = {}) {
  return {
    ...CLIENT,
    ...overrides,
    connect: { ...CLIENT.connect, ...(overrides.connect ?? {}) },
  };
}

function processFactory() {
  const processes = [];
  return {
    processes,
    start(command, args) {
      const lines = [];
      let wake;
      let resolveDone;
      const done = new Promise((resolve) => { resolveDone = resolve; });
      const process = {
        command,
        args,
        cancelCount: 0,
        async *stderr() {
          while (true) {
            if (lines.length) { yield lines.shift(); continue; }
            const line = await new Promise((resolve) => { wake = resolve; });
            if (line === null) return;
            yield line;
          }
        },
        done,
        emit(...newLines) {
          for (const line of newLines) {
            if (wake) { const resolve = wake; wake = undefined; resolve(line); }
            else lines.push(line);
          }
        },
        cancel() { this.cancelCount += 1; resolveDone({ cancelled: true }); wake?.(null); },
      };
      processes.push(process);
      return process;
    },
  };
}

function registered(service) {
  const methods = new Map();
  registerWhatsAppLinkGatewayMethods({
    registerGatewayMethod(name, handler, options) { methods.set(name, { handler, options }); },
  }, service);
  return methods;
}

async function call(method, clientValue, params) {
  let response;
  await method.handler({ client: clientValue, params, respond: (ok, payload) => { response = { ok, payload }; } });
  return response;
}

async function waitFor(predicate) {
  for (let tries = 0; tries < 200; tries += 1) {
    const value = await predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("timed out waiting for link state");
}

test("registers exactly the iPhone link methods as direct admin RPCs", () => {
  const methods = registered(new WacliPhoneLinkService({ startProcess: processFactory().start }));
  assert.deepEqual([...methods.keys()], [
    "operator.whatsappLink.start",
    "operator.whatsappLink.status",
    "operator.whatsappLink.cancel",
  ]);
  for (const { options } of methods.values()) {
    assert.deepEqual(options, { scope: "operator.admin", profileAccess: "required" });
  }
});

test("pinned hyphenated pair codes are accepted and connected waits for confirmation", async () => {
  const runner = processFactory();
  const service = new WacliPhoneLinkService({ startProcess: runner.start });
  const owner = { deviceId: CLIENT.connect.device.id, pairedClientId: CLIENT.pairedClientId };
  const started = service.start(owner, "+14155550123");
  runner.processes[0].emit('{"event":"pair_code","data":{"phone":"14155550123","code":"ABCD-1234"},"ts":1}');
  await waitFor(() => service.status(owner, started.operationId).pairCode === "ABCD-1234");
  runner.processes[0].emit('{"event":"connected","ts":2}');
  await waitFor(() => service.status(owner, started.operationId).phase === "finishing");
  assert.equal(service.status(owner, started.operationId).pairCode, undefined);
});

test("real child completion requires the pinned success envelope and exit zero", async () => {
  for (const [result, exitCode, expected] of [
    [{ success: true, data: { authenticated: true, messages_stored: 0 }, error: null }, 0, "linked"],
    [{ authenticated: true }, 0, "failed"],
    [{ success: true, data: { authenticated: true }, error: null }, 1, "failed"],
  ]) {
    const program = `process.stderr.write(JSON.stringify({event:"connected",ts:1})+"\\n");process.stdout.write(${JSON.stringify(JSON.stringify(result)+"\n")});process.exitCode=${exitCode};`;
    const service = new WacliPhoneLinkService({ startProcess: () => createWacliProcess(process.execPath, ["-e", program]) });
    const owner = { deviceId: CLIENT.connect.device.id, pairedClientId: CLIENT.pairedClientId };
    const started = service.start(owner, "+14155550123");
    await waitFor(() => ["linked", "failed"].includes(service.status(owner, started.operationId).phase));
    assert.equal(service.status(owner, started.operationId).phase, expected);
    assert.equal(service.status(owner, started.operationId).pairCode, undefined);
  }
});

test("pinned error event clears the code without exposing its message", async () => {
  const runner = processFactory();
  const service = new WacliPhoneLinkService({ startProcess: runner.start });
  const owner = { deviceId: CLIENT.connect.device.id, pairedClientId: CLIENT.pairedClientId };
  const started = service.start(owner, "+14155550123");
  runner.processes[0].emit('{"event":"error","data":{"message":"private implementation detail"},"ts":1}');
  await waitFor(() => service.status(owner, started.operationId).phase === "failed");
  assert.deepEqual(service.status(owner, started.operationId), { operationId: started.operationId, phase: "failed" });
});

test("declares a loadable closed-config iPhone plugin package", () => {
  assert.deepEqual(packageManifest.openclaw.extensions, ["./index.js"]);
  assert.equal(packageManifest.openclaw.compat.pluginApi, ">=2026.9.1");
  assert.equal(pluginManifest.id, "operator-iphone-whatsapp-link");
  assert.equal(pluginManifest.activation.onStartup, true);
  assert.deepEqual(pluginManifest.configSchema, {
    type: "object", additionalProperties: false, properties: {},
  });
});

test("start uses the pinned command and ignores forged owner fields in params", async () => {
  const runner = processFactory();
  const methods = registered(new WacliPhoneLinkService({ startProcess: runner.start }));
  const response = await call(methods.get("operator.whatsappLink.start"), client(), {
    phone: "+14155550123", deviceId: "attacker", pairedClientId: "attacker",
  });
  assert.equal(response.ok, true);
  assert.equal(response.payload.phase, "waiting_for_code");
  assert.deepEqual(runner.processes[0].args, ["--events", "--json", "auth", "--phone", "+14155550123"]);
});

test("null, synthetic, and unpaired callers cannot start a link", async () => {
  const runner = processFactory();
  const start = registered(new WacliPhoneLinkService({ startProcess: runner.start })).get("operator.whatsappLink.start");
  for (const unsafe of [null, client({ internal: { syntheticClient: true } }), client({ pairedClientId: undefined })]) {
    const response = await call(start, unsafe, { phone: "+14155550123" });
    assert.deepEqual(response, { ok: false, payload: { error: "not_available" } });
  }
  assert.equal(runner.processes.length, 0);
});

test("the paired device owner can reconnect with changed instance metadata, but another device cannot read or cancel", async () => {
  const runner = processFactory();
  const methods = registered(new WacliPhoneLinkService({ startProcess: runner.start }));
  const started = await call(methods.get("operator.whatsappLink.start"), client(), { phone: "+14155550123" });
  runner.processes[0].emit('{"event":"pair_code","data":{"code":"12345678"}}');
  await waitFor(async () => (await call(methods.get("operator.whatsappLink.status"), client(), { operationId: started.payload.operationId })).payload.phase === "code_ready");

  const reconnect = await call(methods.get("operator.whatsappLink.status"), client({
    connect: { ...CLIENT.connect, client: { id: "openclaw-ios", instanceId: "new-installation-metadata" } },
  }), { operationId: started.payload.operationId });
  assert.equal(reconnect.payload.pairCode, "12345678");

  const other = client({ connect: { ...CLIENT.connect, device: { id: "iphone-device-b" } } });
  assert.deepEqual(await call(methods.get("operator.whatsappLink.status"), other, { operationId: started.payload.operationId }), { ok: false, payload: { error: "not_available" } });
  assert.deepEqual(await call(methods.get("operator.whatsappLink.cancel"), other, { operationId: started.payload.operationId }), { ok: false, payload: { error: "not_available" } });
  assert.equal(runner.processes[0].cancelCount, 0);
});

test("malformed events and implementation errors are redacted from direct responses", async () => {
  const runner = processFactory();
  const service = new WacliPhoneLinkService({ startProcess: runner.start });
  const methods = registered(service);
  const started = await call(methods.get("operator.whatsappLink.start"), client(), { phone: "+14155550123" });
  runner.processes[0].emit("raw secret failure", '{"event":"pair_code","data":{"code":"bad code"}}');
  const status = await call(methods.get("operator.whatsappLink.status"), client(), { operationId: started.payload.operationId });
  assert.equal(status.payload.pairCode, undefined);
  assert.throws(() => service.status({ deviceId: "x", pairedClientId: "x" }, started.payload.operationId), LinkAccessError);
});

test("a queued code cannot restore a cancelled link", async () => {
  const runner = processFactory();
  const service = new WacliPhoneLinkService({ startProcess: runner.start });
  const owner = { deviceId: CLIENT.connect.device.id, pairedClientId: CLIENT.pairedClientId };
  const started = service.start(owner, "+14155550123");
  runner.processes[0].emit('{"event":"pair_code","data":{"code":"12345678"}}');
  service.cancel(owner, started.operationId);
  await new Promise(setImmediate);
  assert.deepEqual(service.status(owner, started.operationId), { operationId: started.operationId, phase: "cancelled" });
});

test("repeated start keeps the same operation but returns its code only from status", async () => {
  const runner = processFactory();
  const service = new WacliPhoneLinkService({ startProcess: runner.start });
  const owner = { deviceId: CLIENT.connect.device.id, pairedClientId: CLIENT.pairedClientId };
  const started = service.start(owner, "+14155550123");
  runner.processes[0].emit('{"event":"pair_code","data":{"code":"12345678"}}');
  await waitFor(() => service.status(owner, started.operationId).phase === "code_ready");
  assert.equal(service.start(owner, "+14155550123").pairCode, undefined);
  assert.equal(service.status(owner, started.operationId).pairCode, "12345678");
  assert.equal(runner.processes.length, 1);
});
