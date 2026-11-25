#!/bin/sh
set -eu
wise_id=wannier90
. /usr/local/lib/devcontainer-features/feature.sh

wise_require linear-algebra
wise_workdir
wise_fetch_git https://github.com/wannier-developers/wannier90.git 1d6b187374a2d50b509e5e79e2cab01a79ff7ce1 "$WISE_WORK/src"
cp "$WISE_WORK/src/config/make.inc.gfort" "$WISE_WORK/src/make.inc"
make -C "$WISE_WORK/src" -j"$(nproc)" wannier
install -s -m 755 "$WISE_WORK/src/wannier90.x" "$WISE_PREFIX/bin/"
wise_done
