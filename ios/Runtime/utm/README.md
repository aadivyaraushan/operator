# Operator UTM SE overlay

This integration pins UTM SE 4.7.5 at commit
`048ca7498ea3a374439149d51739d94c5300bcda` and replaces UTM's existing iOS app
root. Reusing one generated `Platform/iOS/UTMApp.swift` avoids fragile Xcode
project-file edits. The consumer root contains only `ChatScreen`; it does not
expose UTM's VM library, settings form, tabs, or VM commands.

`operator-sources.list` pins every production Swift source under `OperatorCore`
and `OperatorApp`. The apply script checks their combined SHA-256, removes the
same-module `OperatorCore` imports, omits the standalone `OperatorApp` entry
point, and joins the remaining sources with the UTM adapter. The generated
`ChatScreen` restores local history immediately, while its model-setup check is
moved to the point after the VM starts. The unsigned build uses the same iOS 18
minimum as `ios/project.yml`.

The UTM-backed app root:

- copies the bundled `Operator.utm` directory from the app bundle into
  Application Support before loading it;
- uses one Keychain-backed `GatewayInstallationVault` for the VM launch, chat,
  and model setup connections;
- loads `UTMQemuConfiguration` and constructs `UTMQemuVirtualMachine`;
- injects the Gateway token, device ID, and device public key through three
  `fw_cfg` file arguments created with `0700` directory and `0600` file modes,
  then deletes those per-launch files when the VM start call returns;
- starts or lets UTM restore its default suspend snapshot when the app becomes
  active;
- keeps the visible `ChatSessionModel` status at Starting until that succeeds,
  retries its durable outbox once the runtime is ready, and checks model setup
  only after the VM has started;
- opens a second role-specific local node connection while the app is active so
  OpenClaw can invoke foreground-only `location.get` through Core Location;
- saves the default suspend snapshot and stops QEMU when the app enters the
  background, using an iOS background task for the save; and
- emits filterable `[operator-utm]` log messages without guest data or secrets.

No guest, proof disk, UTM source, dependency sysroot, build output, signing
material, or secret is stored here.

## Apply and test

```sh
ios/Runtime/utm/tests/utm_overlay_contract_test.sh
ios/Runtime/utm/scripts/apply-overlay.sh /path/to/UTM
```

The apply script rejects every source commit except the pinned one and checks
the overlay files before changing the source tree. It also applies the minimal
compatibility changes needed to build this UTM release with Xcode 16.4. Those
changes remove source references to Xcode 26-only APIs, one resource whose file
is absent, and the Xcode 26 icon-composer resource. The classic asset catalog is
kept, replaced with the checksum-pinned Operator icon, and configured not to
compile inherited UTM alternate icons.

## Unsigned device archive

Use an external `sysroot-iOS-TCI-arm64` made for this UTM release:

```sh
ios/Runtime/utm/scripts/build-unsigned.sh \
  /path/to/UTM \
  /path/to/sysroot-iOS-TCI-arm64 \
  /path/to/swift-package-cache \
  /tmp/operator-utm-build \
  /path/to/Operator.utm
```

The script builds the `iOS-SE` target for the `iphoneos` SDK and `arm64`, with
code signing disabled and an iOS 18 minimum. It uses the destination-free target
command verified on Xcode 16.4 and checks that the build output contains an
arm64 app. After it embeds `Operator.utm`, it checks every `@rpath` framework
required by the app and its embedded framework binaries. A missing transitive
framework fails the build with the required dependency and expected bundle path.
The Swift package cache is supplied explicitly so a caller can reuse a resolved
cache without storing package sources in this repository.

For a manual Simulator build, run the same check after embedding `Operator.utm`
and before signing:

```sh
ios/Runtime/utm/scripts/verification/check-framework-dependencies.sh \
  /path/to/Operator.app
```

## iOS 18 Simulator proof

On 2026-09-04, the full integrated app was also built for `iphonesimulator`
arm64 and launched on iOS 18.6 build `22G86`. The exact 4.7.5 Simulator
artifact had expired, so this temporary proof used official UTM Actions
artifact `9793038228` from run `33473748927`, commit
`85011a6ca8cb0763f774a5088594b8bfce37811c`. Its verified SHA-256 was
`65826ad14eb9fd22420919a002ea2e40ba579f95400408dc6f48b087a22f0057`.

That newer sysroot added one dependency not embedded by the pinned source:
`vulkan.1.framework`. A complete `otool` audit found it was the only missing
`@rpath` framework, and copying it into the temporary app allowed launch. The
app then needed Xcode's normal local Simulator signing; disabling signing made
Keychain fail with OSStatus `-34018`.

Logs from the running app prove that it copied and protected `Operator.utm`,
started `qemu-system-x86_64`, completed QMP startup, and logged
`[operator-utm] guest started restore=false`. The guest did not yet serve the
forwarded OpenClaw endpoint: a harmless chat attempt ended with URL error
`-1005` and stayed in the durable waiting queue. This is a host/VM execution
proof, not an end-to-end OpenClaw reply proof or a release build recipe.

## Deliberately not claimed

- The Simulator proof does not prove physical-device boot, snapshot restore,
  performance, heat, battery, or iPhone code signing.
- The Simulator QEMU start and `fw_cfg` handoff do not prove that OpenClaw is
  healthy inside the guest; the observed forwarded connection was reset.
- The mixed-commit temporary Simulator build must not become the release recipe.
- The integration does not prove background runtime, suspend reliability, network
  access, OpenClaw compatibility, performance, or App Store acceptance.
- The output is unsigned. Installing it on a stock iPhone requires a separate
  signing and packaging step with the user's Apple developer identity.
