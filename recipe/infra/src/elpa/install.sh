#!/bin/sh
set -eu
wise_id=elpa
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_require scalapack
arch=${CUDAARCH:-80}
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://elpa.mpcdf.mpg.de/software/tarball-archive/Releases/2026.02.002/elpa-2026.02.002.tar.gz \
    02e3c59fec53cd8eb66a4cc15fa4fbf190cf9654227223fb8ad55713e9427932 src
# x86-64-v3 baseline: AVX2 kernels, no AVX-512.
# No test programs: nothing installs them, and HPC-X's mpifort puts a stray quote into the link line of the C ones.
# Check MPI threading under the final image's launcher in verify.sh.
set -- --prefix="$WISE_PREFIX" --disable-static --enable-openmp \
    --without-threading-support-check-during-build --enable-runtime-threading-support-checks --enable-allow-thread-limiting \
    --disable-c-tests --disable-cpp-tests --disable-fortran-tests --disable-Fortran-tests \
    --disable-avx512-kernels --disable-sse-assembly-kernels \
    SCALAPACK_LDFLAGS="-L$WISE_PREFIX/lib -lscalapack -lopenblas" SCALAPACK_FCFLAGS="-I$WISE_PREFIX/include" \
    FC="$WISE_MPI_ROOT/bin/mpifort" CC="$WISE_MPI_ROOT/bin/mpicc" CXX="$WISE_MPI_ROOT/bin/mpicxx"
if wise_cuda; then
    wise_nvfortran_env
    # libtool does not know nvfortran behind mpifort and would compile the Fortran sources without -fPIC.
    export FCFLAGS="$FCFLAGS -fPIC"
    # The HPC SDK keeps cuBLAS and cuSOLVER outside the CUDA directory.
    set -- "$@" --disable-avx2-kernels --disable-avx-kernels --disable-sse-kernels \
        --enable-nvidia-gpu-kernels --with-NVIDIA-GPU-compute-capability=sm_"$arch" \
        --with-cuda-path="$CUDA_HOME" CPPFLAGS="-I$NVHPC_ROOT/math_libs/include" \
        LDFLAGS="-L$NVHPC_ROOT/math_libs/lib64 -L$CUDA_HOME/lib64/stubs" LIBS=-lstdc++
fi
mkdir build
cd build
../src/configure "$@"
make -j"$(nproc)"
make install-strip
test -e "$WISE_PREFIX/lib/libelpa_openmp.so" || wise_fail "the OpenMP build is missing"
wise_done
