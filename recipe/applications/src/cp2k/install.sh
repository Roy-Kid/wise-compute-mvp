#!/bin/sh
set -eu
wise_id=cp2k
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_require_capability cp2k-toolchain
wise_require fftw
wise_require scalapack
deps=$WISE_PREFIX/cp2k-deps
# commit, gpu, elpa, hdf5 and large, as the cp2k-toolchain Feature built them.
# shellcheck source=/dev/null
. "$deps/wise.env"
wise_workdir
work=$WISE_WORK
wise_fetch_git https://github.com/cp2k/cp2k.git "$commit" "$work/src" --all
# CP2K tunes its Release build for the build machine.
native=$work/src/cmake/CompilerConfiguration.cmake
sed -i 's/"-m[a-z]*=native;-mtune=native"/"-march=x86-64-v3;-mtune=generic"/' "$native"
grep -q '"-march=x86-64-v3;-mtune=generic"' "$native" || wise_fail "CP2K's native tuning was not replaced"
if wise_cuda; then
    wise_nvfortran_env
    for flags in CFLAGS CXXFLAGS FFLAGS FCFLAGS F77FLAGS F90FLAGS; do eval "export $flags=\"\$$flags -fPIC\""; done
fi

set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DMPI_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DMPI_CXX_COMPILER="$WISE_MPI_ROOT/bin/mpicxx" \
    -DMPI_Fortran_COMPILER="$WISE_MPI_ROOT/bin/mpifort" \
    -DCP2K_USE_MPI=ON -DCP2K_USE_LIBXC=ON -DCP2K_USE_LIBINT2=ON -DCP2K_USE_FFTW3=ON -DCP2K_USE_LIBXS=ON -DCP2K_USE_LIBXSMM=ON \
    -DCP2K_BLAS_VENDOR=OpenBLAS -DCP2K_SCALAPACK_VENDOR=GENERIC
[ "$elpa" != true ] || set -- "$@" -DCP2K_USE_ELPA=ON
[ "$hdf5" != true ] || set -- "$@" -DCP2K_USE_HDF5=ON
[ "$large" != true ] || set -- "$@" -DCP2K_USE_COSMA=ON -DCP2K_USE_SPLA=ON -DCP2K_USE_SIRIUS=ON \
    -DCP2K_USE_SPGLIB=ON -DCP2K_USE_VORI=ON
[ -z "$gpu" ] || set -- "$@" -DCP2K_USE_ACCEL=CUDA -DCP2K_WITH_GPU="$gpu"
[ -z "$gpu" ] || [ "$large" != true ] || set -- "$@" -DCP2K_USE_SPLA_GEMM_OFFLOADING=ON
if wise_cuda; then
    # CP2K and its dependencies use the same Fortran ABI and OpenMP runtime.
    set -- "$@" -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_Fortran_COMPILER="$FC" \
        -DCP2K_ENABLE_FFTW3_OPENMP_SUPPORT=OFF
fi
# cmakeArgs is a space separated list by contract; no globbing while it is split.
set -f
# shellcheck disable=SC2086
set -- "$@" ${CMAKEARGS:-}
set +f
# SIRIUS's package looks for libfftw3_mpi without a hint.
CMAKE_LIBRARY_PATH="$WISE_PREFIX/lib" bash -c '. "$1/install/setup" && shift && cmake "$@"' sh "$deps" -S "$work/src" -B "$work/build" "$@"
cache=$work/build/CMakeCache.txt
# The toolchain links COSMA and SIRIUS statically, and CMake silently drops an option whose dependency is
# off: check what will actually be built.
for option in MPI LIBXC LIBINT2 FFTW3 LIBXS LIBXSMM $([ "$elpa" != true ] || echo ELPA) \
    $([ "$hdf5" != true ] || echo HDF5) $([ "$large" != true ] || echo COSMA SPLA SIRIUS SPGLIB VORI); do
    grep -q "^CP2K_USE_$option:BOOL=ON$" "$cache" || wise_fail "CP2K_USE_$option is off"
done
if [ -n "$gpu" ]; then
    for option in ENABLE_ELPA_GPU ENABLE_GRID_GPU ENABLE_DBM_GPU ENABLE_PW_GPU \
        $([ "$large" != true ] || echo USE_SPLA_GEMM_OFFLOADING); do
        grep -q "^CP2K_$option:BOOL=ON$" "$cache" || wise_fail "CP2K_$option is off"
    done
    for package in DBCSR $([ "$large" != true ] || echo cosma); do
        grep -q "^${package}_DIR:PATH=.*-cuda/" "$cache" || wise_fail "CP2K found a CPU build of $package"
    done
    uses() { # library symbol: the static library calls the GPU
        nm "$deps"/install/$1 2>/dev/null | grep -q "$2" || wise_fail "$1 is a CPU build"
    }
    if [ "$large" = true ]; then
        uses 'SpFFT-*/lib/libspfft.a' cufftExec
        uses 'SpLA-*/lib/libspla.a' cublas
        uses 'sirius-*/lib/libsirius_cxx.a' __cudaRegisterFatBinary
    fi
fi
cmake --build "$work/build" -j"$(nproc)"
cmake --install "$work/build" --strip
ldconfig
bin=$WISE_PREFIX/bin/cp2k.psmp
wise_mpi_linked "$bin" "$WISE_PREFIX/lib/libfftw3" "$WISE_PREFIX/lib/libscalapack"
[ "$elpa" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libelpa_openmp"
[ "$hdf5" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libhdf5"
[ -z "$gpu" ] || wise_linked "$bin" libcudart
wise_done
