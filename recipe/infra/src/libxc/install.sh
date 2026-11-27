#!/bin/sh
set -eu
wise_id=libxc
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_workdir
wise_fetch_git https://gitlab.com/libxc/libxc.git 0a19bedb24d258b2019eb2d027c1b1039d3e6503 "$WISE_WORK/src"
# The C library serves every compiler of the image; no program here needs fourth derivatives.
cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_C_COMPILER=gcc -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DENABLE_FORTRAN=OFF \
    -DDISABLE_KXC=OFF -DDISABLE_LXC=ON
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build" --strip
test -e "$WISE_PREFIX/lib/libxc.so" || wise_fail "libxc.so was not installed"
wise_done
