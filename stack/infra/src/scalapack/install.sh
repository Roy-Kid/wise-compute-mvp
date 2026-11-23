#!/bin/sh
set -eu
wise_id=scalapack
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_require linear-algebra
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://github.com/Reference-ScaLAPACK/scalapack/archive/refs/tags/v2.2.3.tar.gz \
    5d93701eca663925e98010dd8d0f45fd79b2191d74e5afa5711d587370a8b9dd src
build() { # prefix builddir cmake-args...
    prefix=$1 dir=$2; shift 2
    cmake -S src -B "$dir" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_SHARED_LIBS=ON -DSCALAPACK_BUILD_TESTS=OFF \
        -DCMAKE_C_COMPILER="$WISE_PREFIX/bin/mpicc" -DCMAKE_Fortran_COMPILER="$WISE_PREFIX/bin/mpifort" "$@"
    cmake --build "$dir" -j"$(nproc)"
    cmake --install "$dir" --strip
}
build "$WISE_PREFIX" build
if wise_cuda; then
    # nvfortran copy against the SDK's BLAS/LAPACK, so nvfortran programs never load GCC's OpenMP runtime.
    (wise_nvfortran_env && build "$WISE_NVHPC_PREFIX" build-nvhpc \
        -DBLAS_LIBRARIES="$WISE_SDK_LIB/libblas.so" -DLAPACK_LIBRARIES="$WISE_SDK_LIB/liblapack.so")
    echo "$WISE_NVHPC_PREFIX/lib" > /etc/ld.so.conf.d/wise-nvhpc.conf
    wise_not_linked "$WISE_NVHPC_PREFIX/lib/libscalapack.so" libgomp
fi
wise_done
