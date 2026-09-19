import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const IPHONE_CLIENT_ID = "openclaw-ios";
const ADMIN_SCOPE = "operator.admin";
const PHONE_PATTERN = /^\+[1-9][0-9]{7,14}$/;
const PAIR_CODE_PATTERN = /^(?=.{4,32}$)[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/;
const ACTIVE_PHASES = ["waiting_for_code", "code_ready", "finishing"];
const IDENTIFIER_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
const OPERATION_PATTERN = /^[A-Za-z0-9-]{1,128}$/;

export class LinkAccessError extends Error {
  constructor() {
    super("not_available");
  }
}

function validIdentifier(value) {
  return typeof value === "string" && IDENTIFIER_PATTERN.test(value);
}

function ownerKey(owner) {
  if (!owner || !validIdentifier(owner.deviceId) || owner.pairedClientId !== IPHONE_CLIENT_ID) {
    throw new LinkAccessError();
  }
  return `${owner.deviceId}:${owner.pairedClientId}`;
}

function publicState(operation) {
  const state = { operationId: operation.id, phase: operation.phase };
  if (operation.phase === "code_ready" && operation.pairCode) state.pairCode = operation.pairCode;
  return state;
}

export function verifiedIPhoneOwner(client) {
  const connect = client?.connect;
  const clientId = connect?.client?.id;
  const deviceId = connect?.device?.id;
  if (
    !client ||
    client.internal?.syntheticClient === true ||
    clientId !== IPHONE_CLIENT_ID ||
    client.pairedClientId !== clientId ||
    connect?.role !== "operator" ||
    !Array.isArray(connect.scopes) ||
    !connect.scopes.includes(ADMIN_SCOPE) ||
    !validIdentifier(deviceId)
  ) {
    throw new LinkAccessError();
  }
  return { deviceId, pairedClientId: client.pairedClientId };
}

export function createWacliProcess(command, args) {
  let cancelled = false;
  const child = spawn(command, args, { shell: false, stdio: ["ignore", "pipe", "pipe"] });
  const lines = createInterface({ input: child.stderr });
  let output = "";
  let outputTooLarge = false;
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    if (outputTooLarge) return;
    output += chunk;
    if (Buffer.byteLength(output, "utf8") > 65536) {
      outputTooLarge = true;
      output = "";
      child.kill();
    }
  });
  return {
    async *stderr() {
      for await (const line of lines) yield line;
    },
    done: new Promise((resolve) => {
      child.once("close", (exitCode) => {
        let authenticated = false;
        try {
          const result = JSON.parse(output);
          authenticated = !outputTooLarge && result.success === true && result.error == null && result.data?.authenticated === true;
        } catch { /* Missing or malformed final output never proves linking. */ }
        output = "";
        resolve({ exitCode, cancelled, authenticated });
      });
      child.once("error", () => resolve({ exitCode: null, cancelled, authenticated: false }));
    }),
    cancel() {
      cancelled = true;
      child.kill();
    },
  };
}

export class WacliPhoneLinkService {
  constructor({ startProcess = createWacliProcess } = {}) {
    this.startProcess = startProcess;
    this.operations = new Map();
  }

  start(owner, phone) {
    const key = ownerKey(owner);
    if (!PHONE_PATTERN.test(phone ?? "")) throw new LinkAccessError();
    const existing = [...this.operations.values()].find((operation) => operation.ownerKey === key && ACTIVE_PHASES.includes(operation.phase));
    if (existing) return { operationId: existing.id, phase: existing.phase };

    const process = this.startProcess("wacli", ["--events", "--json", "auth", "--phone", phone]);
    const operation = {
      id: randomUUID(), ownerKey: key, process, phase: "waiting_for_code", pairCode: undefined,
    };
    this.operations.set(operation.id, operation);
    this.consume(operation);
    return publicState(operation);
  }

  status(owner, operationId) {
    return publicState(this.operationFor(owner, operationId));
  }

  cancel(owner, operationId) {
    const operation = this.operationFor(owner, operationId);
    if (ACTIVE_PHASES.includes(operation.phase)) {
      operation.phase = "cancelled";
      operation.pairCode = undefined;
      operation.process.cancel();
    }
    return publicState(operation);
  }

  operationFor(owner, operationId) {
    const key = ownerKey(owner);
    if (typeof operationId !== "string" || !OPERATION_PATTERN.test(operationId)) throw new LinkAccessError();
    const operation = this.operations.get(operationId);
    if (!operation || operation.ownerKey !== key) throw new LinkAccessError();
    return operation;
  }

  async consume(operation) {
    try {
      for await (const line of operation.process.stderr()) this.consumeEvent(operation, line);
      const result = await operation.process.done;
      if (ACTIVE_PHASES.includes(operation.phase)) {
        operation.phase = result?.cancelled ? "cancelled" : (result?.exitCode === 0 && result.authenticated === true ? "linked" : "failed");
        operation.pairCode = undefined;
      }
    } catch {
      if (ACTIVE_PHASES.includes(operation.phase)) {
        operation.phase = "failed";
        operation.pairCode = undefined;
      }
    }
  }

  consumeEvent(operation, line) {
    if (!ACTIVE_PHASES.includes(operation.phase)) return;
    let event;
    try { event = JSON.parse(line); } catch { return; }
    if (event?.event === "pair_code" && PAIR_CODE_PATTERN.test(event?.data?.code ?? "")) {
      operation.phase = "code_ready";
      operation.pairCode = event.data.code;
    } else if (event?.event === "error") {
      operation.phase = "failed";
      operation.pairCode = undefined;
    } else if (event?.event === "connected") {
      operation.phase = "finishing";
      operation.pairCode = undefined;
    }
  }
}

export function registerWhatsAppLinkGatewayMethods(api, service) {
  const register = (method, action) => api.registerGatewayMethod(method, async ({ client, params, respond }) => {
    api.logger?.debug?.(`[whatsapp-link] ${method} request received`);
    try {
      const owner = verifiedIPhoneOwner(client);
      const result = action(owner, params ?? {});
      api.logger?.debug?.(`[whatsapp-link] ${method} phase=${result.phase}`);
      respond(true, result);
    } catch {
      api.logger?.warn?.(`[whatsapp-link] ${method} unavailable`);
      respond(false, { error: "not_available" });
    }
  }, { scope: ADMIN_SCOPE, profileAccess: "required" });

  register("operator.whatsappLink.start", (owner, params) => service.start(owner, params.phone));
  register("operator.whatsappLink.status", (owner, params) => service.status(owner, params.operationId));
  register("operator.whatsappLink.cancel", (owner, params) => service.cancel(owner, params.operationId));
}
