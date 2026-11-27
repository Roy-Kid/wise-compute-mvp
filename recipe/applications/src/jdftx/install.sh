#!/bin/sh
set -eu
wise_id=jdftx
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

variant=${VARIANT:-cpu}
arch=${CUDAARCH:-80}
case "$variant" in
    cpu) ;;
    cuda)
        wise_cuda || wise_fail "variant=cuda needs the CUDA base image"
        echo "$arch" | grep -qx '[1-9][0-9]*' || wise_fail "cudaArch is a compute capability such as 80, not $arch"
        ;;
    *) wise_fail "unknown variant $variant" ;;
esac
wise_apt libgsl-dev
wise_workdir
wise_fetch_git https://github.com/shankar1729/jdftx.git 1f477ccee37aeddd15e3721bba30e46a7585aa01 "$WISE_WORK/src"

# JDFTx looks for ATLAS by default; OpenBLAS provides CBLAS and LAPACK in one library.
openblas=/usr/lib/x86_64-linux-gnu/libopenblas.so
test -e "$openblas" || wise_fail "OpenBLAS is not at $openblas"
set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" -DCMAKE_PREFIX_PATH="$WISE_PREFIX" \
    -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DCBLAS_LIBRARY="$openblas" -DLAPACK_LIBRARIES="$openblas" \
    -DFFTW3_PATH="$WISE_PREFIX" -DEnableLibXC=yes -DLIBXC_PATH="$WISE_PREFIX" -DEnableHDF5=no -DCompileNative=no
if wise_mpi; then
    set -- "$@" -DEnableMPI=yes -DMPI_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DMPI_CXX_COMPILER="$WISE_MPI_ROOT/bin/mpicxx"
    ! wise_has scalapack || set -- "$@" -DEnableScaLAPACK=yes -DSCALAPACK_PATH="$WISE_PREFIX"
else
    set -- "$@" -DEnableMPI=no
fi
if [ "$variant" = cuda ]; then
    # The HPC SDK keeps cuBLAS, cuFFT and cuSOLVER outside the CUDA directory, and its MPI passes GPU memory directly.
    # The GPU programs need the CUDA driver, which the SDK supplies on GPU-less builders.
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$CUDA_HOME/compat"
    set -- "$@" -DEnableCUDA=yes -DEnableCuSolver=yes -DCUDA_TOOLKIT_ROOT_DIR="$CUDA_HOME" \
        -DCMAKE_LIBRARY_PATH="${NVHPC_ROOT:?}/math_libs/lib64" -DCMAKE_INCLUDE_PATH="$NVHPC_ROOT/math_libs/include" \
        -DCUDA_ARCH="compute_$arch" -DCUDA_CODE="sm_$arch"
    ! wise_mpi || set -- "$@" -DCudaAwareMPI=yes
else
    set -- "$@" -DEnableCUDA=no
fi
cmake -S "$WISE_WORK/src/jdftx" -B "$WISE_WORK/build" "$@"
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build"
ldconfig
programs=jdftx
[ "$variant" != cuda ] || programs="jdftx jdftx_gpu"
for program in $programs; do
    if wise_mpi; then wise_mpi_linked "$WISE_PREFIX/bin/$program" "$WISE_PREFIX/lib/libfftw3" "$WISE_PREFIX/lib/libxc" libopenblas libgsl
    else wise_linked "$WISE_PREFIX/bin/$program" "$WISE_PREFIX/lib/libfftw3" "$WISE_PREFIX/lib/libxc" libopenblas libgsl
        wise_not_linked "$WISE_PREFIX/bin/$program" libmpi; fi
done
[ "$variant" != cuda ] || wise_linked "$WISE_PREFIX/bin/jdftx_gpu" libcusolver libcublas libcufft
test -d "$WISE_PREFIX/share/jdftx/pseudopotentials/GBRV" || wise_fail "the GBRV pseudopotentials were not installed"
wise_done
