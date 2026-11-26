#!/bin/sh
# CP2K needs gfortran (nvfortran does not compile DBCSR), and the MPI of the CUDA base has Fortran modules for
# nvfortran only. On that base CP2K therefore gets a GNU stack of its own, built by its toolchain and kept apart
# from the image's MPI: nothing here may end up in the dynamic loader's cache or in the default PATH.

cp2k_gnu_stack() { [ -n "${CUDA_HOME:-}" ]; }

# The build environment: GNU compilers, CUDA, and no trace of the image's MPI or of the NVHPC compiler runtime.
cp2k_gnu_env() {
    unset OPAL_PREFIX OMPI_CC OMPI_CXX OMPI_FC OMPI_MCA_pml MPICH_CC MPICH_CXX MPICH_FC
    export CC=gcc CXX=g++ FC=gfortran F77=gfortran F90=gfortran
    PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$NVHPC_ROOT/comm_libs/" | paste -sd: -)
    export PATH
    # cuFFT, cuBLAS and cuSOLVER are in the SDK's math_libs; the system directory first keeps GNU OpenMP.
    export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:$CUDA_HOME/lib64:$NVHPC_ROOT/math_libs/lib64"
    export LIBRARY_PATH="$CUDA_HOME/lib64:$NVHPC_ROOT/math_libs/lib64"
    export CPATH="$NVHPC_ROOT/math_libs/include"
    export CUDA_PATH="$CUDA_HOME"
    command -v gfortran >/dev/null || { echo "CP2K: gfortran is missing" >&2; return 1; }
    ! command -v mpirun >/dev/null || { echo "CP2K: the image's MPI is still on PATH" >&2; return 1; }
}

# The toolchain's own MPI, BLAS, FFTW and ScaLAPACK, the same in every run that continues in one tree.
cp2k_gnu_toolchain_args() {
    printf '%s\n' --with-openmpi=install --with-openblas=install --with-fftw=install --with-scalapack=install
}
