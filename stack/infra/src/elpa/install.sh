#!/bin/sh
set -eu
. /opt/wise/lib/wise/feature.sh elpa

wise_require_capability mpi
wise_require scalapack
arch=${CUDAARCH:-80}
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://elpa.mpcdf.mpg.de/software/tarball-archive/Releases/2026.02.002/elpa-2026.02.002.tar.gz \
    02e3c59fec53cd8eb66a4cc15fa4fbf190cf9654227223fb8ad55713e9427932 src
build() { # prefix builddir configure-args...
    prefix=$1 dir=$2; shift 2
    mkdir "$dir"
    (cd "$dir" && ../src/configure --prefix="$prefix" --disable-static --disable-avx512-kernels \
        --disable-sse-assembly-kernels FC="$WISE_PREFIX/bin/mpifort" CC="$WISE_PREFIX/bin/mpicc" "$@" \
        && make -j"$(nproc)" && make install-strip)
}
# x86-64-v3 baseline: AVX2 kernels, no AVX-512.
set -- --enable-openmp SCALAPACK_LDFLAGS="-L$WISE_PREFIX/lib -lscalapack -lopenblas" \
    SCALAPACK_FCFLAGS="-I$WISE_PREFIX/include"
if wise_cuda; then
    set -- "$@" --enable-nvidia-gpu-kernels --with-NVIDIA-GPU-compute-capability=sm_"$arch" \
        --with-cuda-path="$CUDA_HOME" LDFLAGS="-L$CUDA_HOME/lib64/stubs"
fi
build "$WISE_PREFIX" build "$@"
if wise_cuda; then
    # nvfortran programs (QE GPU) use Fortran modules of their own compiler, without GCC's OpenMP.
    (wise_nvfortran_env && build "$WISE_NVHPC_PREFIX" build-nvhpc --disable-openmp \
        --disable-avx2-kernels --disable-avx-kernels --disable-sse-kernels \
        SCALAPACK_LDFLAGS="-L$WISE_NVHPC_PREFIX/lib -lscalapack -L$WISE_SDK_LIB -llapack -lblas")
    echo "$WISE_NVHPC_PREFIX/lib" > /etc/ld.so.conf.d/wise-nvhpc.conf
fi
test -e "$WISE_PREFIX/lib/libelpa_openmp.so" || wise_fail "the OpenMP build is missing"
wise_done
