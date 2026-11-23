#!/bin/sh
set -eu
wise_id=mpich
. /opt/wise/lib/wise/feature.sh

wise_require libfabric
# One MPI per image: openmpi and mpich both claim the mpi capability.
wise_provide mpi
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://www.mpich.org/static/downloads/4.3.2/mpich-4.3.2.tar.gz \
    47d774587a7156a53752218c811c852e70ac44db9c502dc3f399b4cb817e3818 src
cd src
set -- --prefix="$WISE_PREFIX" --disable-static CC=gcc CXX=g++ FC=gfortran \
    --with-device=ch4:ofi --with-libfabric="$WISE_PREFIX" --with-hwloc=embedded
if wise_cuda; then set -- "$@" --with-cuda="$CUDA_HOME"; fi
./configure "$@"
make -j"$(nproc)"
make install-strip
ldconfig
"$WISE_PREFIX/bin/mpichversion" | grep -q 'ch4:ofi' || wise_fail "MPICH was not built with the ch4:ofi device"
wise_linked "$WISE_PREFIX/lib/libmpi.so" "$WISE_PREFIX/lib/libfabric"
wise_done
