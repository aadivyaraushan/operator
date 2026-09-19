#!/bin/sh
# Contract checks for the host-only production guest image builder.
set -eu

runtime_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
builder="$runtime_dir/guest/image-build/build-production-guest.sh"
stager="$runtime_dir/guest/image-build/stage-wacli.sh"
npm_stager="$runtime_dir/guest/image-build/openclaw-runtime/stage-npm.sh"
runtime_packager="$runtime_dir/guest/image-build/openclaw-runtime/restore-workspace-templates.sh"
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_text() {
  grep -Fq -- "$1" "$builder" || fail "builder lacks: $1"
}

test -f "$builder" || fail 'production guest builder is missing'
test -f "$stager" || fail 'wacli staging helper is missing'
test -x "$npm_stager" || fail 'npm runtime staging helper is missing or not executable'
test -f "$runtime_packager" || fail 'runtime packager is missing'

if test -f "$builder"; then
  require_text '--alpine-qcow2'
  require_text '--runtime-archive'
  require_text '--runtime-apks'
  require_text '--wacli'
  require_text '--output-qcow2'
  require_text '--work-dir'
  require_text '--run-qemu'
  require_text 'OPENCLAW_RUNTIME_ARCHIVE'
  require_text 'refusing to overwrite'
  require_text 'sha512sum -c'
  require_text 'sha256sum -c'
  require_text 'mkisofs -output "$seed_iso"'
  require_text 'mkisofs -output "$payload_iso"'
  require_text '-volid cidata'
  require_text '-volid OPERATOR_PAYLOAD'
  require_text 'build-clean-image.sh'
  require_text 'qemu-system-x86_64'
  require_text 'stage-wacli.sh'
  require_text 'if test "$run_qemu" = true; then'
  require_text 'OPERATOR_PROVISIONING_COMPLETE'
  require_text 'provisioning completion marker is missing'
  require_text 'no_ssh_fingerprints: true'
  require_text 'rm -f /root/.ssh/authorized_keys /home/alpine/.ssh/authorized_keys'
  if grep -Eq '(curl|wget|ssh-keygen|password[[:space:]]*=|OPENCLAW_GATEWAY_TOKEN[[:space:]]*=)' "$builder"; then
    fail 'builder includes a download, SSH key, password, or gateway token path'
  fi
fi

if test -f "$builder"; then
  flow_test_dir=$(mktemp -d)
  flow_script=$flow_test_dir/provision-flow.sh
  awk '/^    set -eu$/,/^    provisioning_status=0$/' "$builder" |
    sed 's/^    //; s/\\\$/\$/g; s#/mnt/operator-payload/guest/first-boot/provision-guest.sh#provision-guest#; s#/dev/ttyS0#"$TEST_LOG"#g' >"$flow_script"
  command_stub=$flow_test_dir/command-stub
  cat >"$command_stub" <<'EOF'
#!/bin/sh
name=${0##*/}
printf '%s\n' "$name" >>"$CALL_LOG"
test "${FAIL_COMMAND:-}" != "$name"
EOF
  chmod +x "$command_stub"
  for name in mkdir mount provision-guest rm sync poweroff; do
    ln -s command-stub "$flow_test_dir/$name"
  done
  for failure in mount provision-guest rm; do
    : >"$flow_test_dir/result"
    : >"$flow_test_dir/calls"
    PATH="$flow_test_dir:$PATH" TEST_LOG="$flow_test_dir/result" CALL_LOG="$flow_test_dir/calls" OPENCLAW_RUNTIME_ARCHIVE=runtime.tar.gz FAIL_COMMAND="$failure" sh "$flow_script" || true
    grep -Fq OPERATOR_PROVISIONING_FAILED "$flow_test_dir/result" || fail "$failure failure emits success or lacks failure marker"
    ! grep -Fq OPERATOR_PROVISIONING_COMPLETE "$flow_test_dir/result" || fail "$failure failure emits the completion marker"
  done
  : >"$flow_test_dir/result"
  : >"$flow_test_dir/calls"
  PATH="$flow_test_dir:$PATH" TEST_LOG="$flow_test_dir/result" CALL_LOG="$flow_test_dir/calls" OPENCLAW_RUNTIME_ARCHIVE=runtime.tar.gz sh "$flow_script" || fail 'successful provisioning flow exits nonzero'
  grep -Fq OPERATOR_PROVISIONING_COMPLETE "$flow_test_dir/result" || fail 'successful provisioning flow lacks completion marker'
  test "$(tail -n 2 "$flow_test_dir/calls" | tr '\n' ' ')" = 'sync poweroff ' || fail 'successful provisioning does not sync immediately before clean poweroff'
fi

if test -x "$npm_stager"; then
  require_text() {
    grep -Fq -- "$1" "$npm_stager" || fail "npm stager lacks: $1"
  }
  require_text 'npm archive digest mismatch'
  require_text '"version": "10.9.8",'
  require_text '"node": "^18.17.0 || >=20.5.0"'
  require_text 'bin/npm-cli.js'
  require_text 'bin/npx-cli.js'
  require_text 'refusing to overwrite packaged npm paths'
fi

if test -f "$runtime_packager"; then
  grep -Fq '"$script_dir/stage-timing/apply.sh" "$staging_root"' "$runtime_packager" || fail 'runtime packager does not apply timing-only diagnostics to staged runtime'
  grep -Fq 'stage-npm.sh' "$runtime_packager" || fail 'runtime packager does not stage npm into the archive'
  grep -Fq 'npm-10.9.8.tgz' "$runtime_packager" || fail 'runtime packager does not require the pinned npm archive'
  grep -Fq 'managed_project=${5:-}' "$runtime_packager" || fail 'runtime packager does not require a managed Codex project input'
  grep -Fq 'verify-managed-project.mjs' "$runtime_packager" || fail 'runtime packager does not verify the managed Codex project'
  grep -Fq 'usr/local/share/openclaw-plugins' "$runtime_packager" || fail 'runtime packager does not stage the managed Codex project in the runtime archive'
  grep -Fq 'sha512-0Ve0631CdgkJDwd4NNG1BawIdF5yCL2sO+Tts8amStw+H6vKURTj0K4rOa4+hFpJk1Dnw5LyKl5twzwX1VtA2w==' "$runtime_packager" || fail 'runtime packager does not pin the published OpenClaw source archive'
  grep -Fq 'openclaw archive digest mismatch' "$runtime_packager" || fail 'runtime packager does not reject a changed OpenClaw source archive'
  grep -Fq 'dist/build-info.json' "$runtime_packager" || fail 'runtime packager does not validate the extracted OpenClaw build commit'
  grep -Fq 'missing pinned CLAUDE.md' "$runtime_packager" || fail 'runtime packager does not fail when the r4-provenance CLAUDE template is absent'
  grep -Fq 'cmp -s "$pinned_claude_template" "$pinned_agents_template"' "$runtime_packager" || fail 'runtime packager does not verify the retained CLAUDE compatibility alias'
fi

if test -f "$stager"; then
  staging_test_dir=$(mktemp -d)
  trap 'rm -rf "$staging_test_dir"' EXIT HUP INT TERM
  good_artifact="$staging_test_dir/good-wacli"
  wrong_artifact="$staging_test_dir/wrong-wacli"
  manifest="$staging_test_dir/wacli.sha256"
  printf '%s\n' 'verified static wacli fixture' >"$good_artifact"
  printf '%s\n' 'wrong wacli fixture' >"$wrong_artifact"
  good_digest=$(sha256sum "$good_artifact" | awk '{print $1}')
  printf '%s  wacli\n' "$good_digest" >"$manifest"

  if "$stager" "$staging_test_dir/missing" "$manifest" "$staging_test_dir/missing-output"; then
    fail 'wacli stager accepts a missing artifact'
  fi
  if "$stager" "$wrong_artifact" "$manifest" "$staging_test_dir/wrong-output"; then
    fail 'wacli stager accepts an artifact with the wrong digest'
  fi
  if ! "$stager" "$good_artifact" "$manifest" "$staging_test_dir/valid-output"; then
    fail 'wacli stager rejects a matching artifact'
  elif ! test -x "$staging_test_dir/valid-output/wacli" || \
    ! (cd "$staging_test_dir/valid-output" && sha256sum -c wacli.sha256 >/dev/null); then
    fail 'wacli stager does not create a checked executable payload'
  fi
fi

if test "$failures" -gt 0; then
  exit 1
fi

printf 'PASS: production guest image builder contract\n'
