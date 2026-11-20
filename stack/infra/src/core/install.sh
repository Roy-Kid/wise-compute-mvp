#!/bin/sh
set -eu

prefix=/opt/wise
mkdir -p "$prefix/bin" "$prefix/lib/wise" "$prefix/include" "$prefix/share/wise/features/provides"
install -m 0644 "$(dirname "$0")/feature.sh" "$prefix/lib/wise/feature.sh"
echo "$prefix/lib" > /etc/ld.so.conf.d/wise.conf
ldconfig
# core registers itself through its own SDK, like every other Feature.
. "$prefix/lib/wise/feature.sh" core
wise_done
