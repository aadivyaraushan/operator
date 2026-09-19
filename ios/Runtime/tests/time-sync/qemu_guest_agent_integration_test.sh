#!/bin/sh
# Boots a disposable overlay to prove the packaged QEMU agent accepts only time RPCs.
set -eu

if test "$#" -ne 1; then
  printf 'usage: %s PROVISIONED_GUEST_QCOW2\n' "$0" >&2
  exit 64
fi

image_input=$1
test -f "$image_input" || {
  printf 'guest image is missing: %s\n' "$image_input" >&2
  exit 66
}
image=$(CDPATH= cd -- "$(dirname -- "$image_input")" && pwd)/$(basename -- "$image_input")

test_dir=$(mktemp -d)
overlay=$test_dir/guest-overlay.qcow2
socket_path=$test_dir/qga.sock
qemu_log=$test_dir/qemu.log
qemu_pid=

cleanup() {
  if test -n "$qemu_pid" && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

qemu-img create -f qcow2 -F qcow2 -b "$image" "$overlay" >/dev/null
qemu-system-x86_64 -m 2048 -smp 2 \
  -drive "file=$overlay,if=virtio,format=qcow2" \
  -nic none \
  -device virtio-serial-pci \
  -chardev "socket,id=qga,path=$socket_path,server=on,wait=off" \
  -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0 \
  -nographic -no-reboot >"$qemu_log" 2>&1 &
qemu_pid=$!

node - "$socket_path" <<'NODE'
const net = require('node:net');

const socketPath = process.argv[2];
const requests = [
  { id: 'set-time', execute: 'guest-set-time', arguments: { time: Date.now() * 1_000_000 }, allowed: true },
  { id: 'deny-exec', execute: 'guest-exec', arguments: { path: '/bin/true' }, allowed: false },
  { id: 'deny-file-open', execute: 'guest-file-open', arguments: { path: '/proc/version', mode: 'r' }, allowed: false },
];

function fail(message) {
  process.stderr.write(`FAIL: ${message}\n`);
  process.exit(1);
}

function decodeQgaBytes(bytes) {
  return Buffer.from(bytes.filter((byte) => byte !== 0xff)).toString('utf8');
}

if (decodeQgaBytes(Buffer.from([0xff, 0x7b, 0x7d, 0x0a])) !== '{}\n') {
  fail('QGA framing fixture did not remove the raw delimiter byte');
}

function tryConnect() {
  const socket = net.createConnection(socketPath);
  let buffer = Buffer.alloc(0);
  let current = 0;
  let ready = false;
  const deadline = setTimeout(() => fail('guest agent did not become ready within 120 seconds'), 120_000);
  let readinessRetry;

  function write(request, delimiter = false) {
    const json = Buffer.from(`${JSON.stringify({ execute: request.execute, arguments: request.arguments, id: request.id })}\n`);
    socket.write(delimiter ? Buffer.concat([Buffer.from([0xff]), json]) : json);
  }

  function finish() {
    clearTimeout(deadline);
    clearInterval(readinessRetry);
    socket.end();
    // guest-get-time is intentionally denied, so this only proves the
    // permitted set-time RPC was accepted; it does not measure clock error.
    process.exit(0);
  }

  socket.on('connect', () => {
    const readinessRequest = { id: 'readiness', execute: 'guest-sync-delimited', arguments: { id: 13579 } };
    write(readinessRequest, true);
    readinessRetry = setInterval(() => write(readinessRequest, true), 5_000);
  });
  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    let newline;
    while ((newline = buffer.indexOf(0x0a)) >= 0) {
      const line = decodeQgaBytes(buffer.subarray(0, newline)).trim();
      buffer = buffer.subarray(newline + 1);
      if (!line) continue;
      let response;
      try { response = JSON.parse(line); } catch { continue; }
      if (!ready) {
        if (response.id !== 'readiness' || !Object.hasOwn(response, 'return')) continue;
        ready = true;
        clearInterval(readinessRetry);
        write(requests[current]);
        continue;
      }
      const request = requests[current];
      if (response.id !== request.id) continue;
      if (request.allowed && !Object.hasOwn(response, 'return')) {
        fail(`${request.execute} was not accepted: ${line}`);
      }
      if (!request.allowed && (!response.error || !/(disabled|not allowed|unknown command)/i.test(JSON.stringify(response.error)))) {
        fail(`${request.execute} was not explicitly denied: ${line}`);
      }
      current += 1;
      if (current === requests.length) finish();
      else write(requests[current]);
    }
  });
  socket.on('error', (error) => {
    fail(`guest agent did not become available after boot: ${error.message}`);
  });
}

tryConnect();
NODE

printf 'PASS: QEMU guest agent accepts guest-sync-delimited and guest-set-time; exec and file-open are explicitly denied\n'
