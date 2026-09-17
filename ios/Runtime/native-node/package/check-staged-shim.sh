#!/bin/sh
# Fails the app build when the staged runtime lacks the Intl.Segmenter
# replacement. build/native-node/runtime is generated per machine and ignored
# by git, so a copy staged before compat/intl/segmenter.mjs existed builds
# without complaint and then crashes the app on the first reply that segments
# text (2026-09-17, JSSegments::Create). Run from the ios directory.
set -eu
source_root="Runtime/native-node"
staged_root="build/native-node/runtime"
for name in entry.mjs compat/intl/segmenter.mjs; do
  if ! cmp -s "$source_root/$name" "$staged_root/$name"; then
    echo "error: staged runtime is out of date: $staged_root/$name does not match $source_root/$name. Restage with Runtime/bootstrap.sh (see Runtime/DEPENDENCIES.md)." >&2
    exit 1
  fi
done
echo "[staged-runtime] Intl.Segmenter replacement present"
