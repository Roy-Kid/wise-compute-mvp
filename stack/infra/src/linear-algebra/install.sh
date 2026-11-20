#!/bin/sh
set -eu
. /opt/wise/lib/wise/feature.sh linear-algebra

wise_apt libopenblas-openmp-dev
for lib in libblas.so.3 liblapack.so.3; do
    readlink -f "/usr/lib/x86_64-linux-gnu/$lib" | grep -q openblas-openmp \
        || wise_fail "$lib does not resolve to OpenBLAS (OpenMP)"
done
wise_done
