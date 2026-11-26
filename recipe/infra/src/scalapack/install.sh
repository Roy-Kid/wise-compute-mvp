#!/bin/sh
set -eu
wise_id=scalapack
. /usr/local/lib/devcontainer-features/feature.sh

wise_require_capability mpi
wise_require linear-algebra
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://github.com/Reference-ScaLAPACK/scalapack/archive/refs/tags/v2.2.3.tar.gz \
    5d93701eca663925e98010dd8d0f45fd79b2191d74e5afa5711d587370a8b9dd src
if wise_cuda; then
    wise_nvfortran_env
    # ScaLAPACK 2.2.3 gives this file a GCC warning option that nvc rejects.
    sed -i '/set_source_files_properties(TOOLS\/SL_gridreshape.c .*Wno-error=implicit-function-declaration/d' src/CMakeLists.txt
fi
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DBUILD_SHARED_LIBS=ON -DSCALAPACK_BUILD_TESTS=OFF -DBLA_VENDOR=OpenBLAS \
    -DCMAKE_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DCMAKE_Fortran_COMPILER="$WISE_MPI_ROOT/bin/mpifort"
cmake --build build -j"$(wise_build_jobs)"
cmake --install build --strip
wise_done
