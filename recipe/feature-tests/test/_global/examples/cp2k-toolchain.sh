#!/bin/sh
set -eu
test -s /usr/local/cp2k-deps/install/setup
test -s /usr/local/cp2k-deps/wise.env
for library in libdbcsr libxsmm libsirius_cxx; do
    test -n "$(find /usr/local/cp2k-deps/install -name "$library.*" -print -quit)"
done
