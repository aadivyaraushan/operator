#!/bin/sh
# Fails the app build when the staged runtime is older than the source.
# build/native-node/runtime is generated per machine and ignored by git, so a copy staged before compat/intl/segmenter.mjs existed builds
# without complaint and then crashes the app on the first reply that segments
# text (2026-09-17, JSSegments::Create). Run from the ios directory.
set -eu
source_root="Runtime/native-node"
staged_root="build/native-node/runtime"
for name in entry.mjs host/start.mjs gateway/state.mjs package/workspace-guidance.mjs compat/intl/segmenter.mjs; do
  if ! cmp -s "$source_root/$name" "$staged_root/$name"; then
    echo "error: staged runtime is out of date: $staged_root/$name does not match $source_root/$name. Restage with Runtime/bootstrap.sh (see Runtime/DEPENDENCIES.md)." >&2
    exit 1
  fi
done
# The OpenClaw patches are applied at staging time; the manifest names them.
for patch in native-lock-directory native-recovery-source-run native-ios-restart-safe-admission native-search-completion-log; do
  if ! grep -q "\"$patch\"" "$staged_root/manifest.json"; then
    echo "error: staged runtime is out of date: $staged_root/manifest.json lacks the $patch patch. Restage with Runtime/bootstrap.sh (see Runtime/DEPENDENCIES.md)." >&2
    exit 1
  fi
done
echo "[staged-runtime] host files and patches match the source"
