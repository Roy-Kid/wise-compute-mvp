#!/bin/sh
set -eu
wise_id=linear-algebra
. /opt/wise/lib/wise/feature.sh

backend=openmp
if wise_cuda; then backend=pthread; fi
wise_apt "libopenblas-$backend-dev"
for lib in libblas.so.3 liblapack.so.3; do
    readlink -f "/usr/lib/x86_64-linux-gnu/$lib" | grep -q "openblas-$backend" \
        || wise_fail "$lib does not resolve to OpenBLAS ($backend)"
done
wise_done
