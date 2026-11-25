#!/bin/sh
set -eu

prefix=/usr/local
mkdir -p "$prefix/bin" "$prefix/lib/devcontainer-features" "$prefix/include" "$prefix/share/devcontainer-features/provides"
install -m 0644 "$(dirname "$0")/feature.sh" "$prefix/lib/devcontainer-features/feature.sh"
# core registers itself through its own SDK, like every other Feature.
wise_id=core
. "$prefix/lib/devcontainer-features/feature.sh"
wise_done
