#!/bin/sh
set -eu

prefix=/usr/local
sdk=$prefix/lib/devcontainer-features
mkdir -p "$prefix/bin" "$sdk" "$prefix/include" "$prefix/share/devcontainer-features/provides"
for file in feature.sh deps.sh build.sh; do install -m 0644 "$(dirname "$0")/$file" "$sdk/$file"; done
install -m 0755 "$(dirname "$0")/wise-features" "$prefix/bin/wise-features"
# core registers itself through its own SDK, like every other Feature.
wise_id=core
. "$sdk/feature.sh"
wise_sdk 4
wise_done
