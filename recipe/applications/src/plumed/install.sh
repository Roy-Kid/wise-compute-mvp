#!/bin/sh
set -eu
wise_id=plumed
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_require linear-algebra
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://github.com/plumed/plumed2/releases/download/v2.10.2/plumed-src-2.10.2.tgz \
    42f097dd148275bbcd72034815655391d4743be06d1cea500ef848c84b8462dc src
cd src
./configure --prefix="$WISE_PREFIX" CC="$WISE_MPI_ROOT/bin/mpicc" CXX="$WISE_MPI_ROOT/bin/mpicxx" --disable-doc
make -j"$(nproc)"
make install
wise_mpi_linked "$WISE_PREFIX/lib/libplumed.so"
wise_done
