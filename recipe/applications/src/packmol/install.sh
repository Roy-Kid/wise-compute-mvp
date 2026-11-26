#!/bin/sh
set -eu
wise_id=packmol
. /usr/local/lib/devcontainer-features/feature.sh

wise_require openmp
wise_workdir
wise_fetch_git https://github.com/m3g/packmol.git d70e10b13033dfbd3eb4d00b1b803989f17b1452 "$WISE_WORK/src"
cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX"
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build" --strip
test -x "$WISE_PREFIX/bin/packmol" || wise_fail "packmol was not installed"
wise_done
