#!/bin/sh
set -eu
test -s /usr/local/cp2k-deps/install/setup
for library in libint2 libxc; do
    test -n "$(find /usr/local/cp2k-deps/install -name "$library.*" -print -quit)"
done
