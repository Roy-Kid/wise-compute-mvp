#!/bin/sh
set -eu
wise_id=cp2k
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_require_capability cp2k-toolchain
deps=$WISE_PREFIX/cp2k-deps
# On the CUDA base CP2K has a GNU stack of its own; see the cp2k-integrals Feature.
. "$deps/gnu-stack.sh"
# commit, mpi, gpu, elpa, hdf5 and large, as the earlier CP2K Features built them.
# shellcheck source=/dev/null
. "$deps/wise.env"
if ! cp2k_gnu_stack && [ "$mpi" != none ]; then
    wise_require_capability mpi
    wise_require scalapack
fi
wise_workdir
work=$WISE_WORK
wise_fetch_git https://github.com/cp2k/cp2k.git "$commit" "$work/src" --all
# CP2K tunes its Release build for the build machine.
native=$work/src/cmake/CompilerConfiguration.cmake
sed -i 's/"-m[a-z]*=native;-mtune=native"/"-march=x86-64-v3;-mtune=generic"/' "$native"
grep -q '"-march=x86-64-v3;-mtune=generic"' "$native" || wise_fail "CP2K's native tuning was not replaced"
if cp2k_gnu_stack; then
    cp2k_gnu_env
    # Out of the default PATH and loader directories: the commands in $WISE_PREFIX/bin set its environment.
    prefix=$deps/cp2k
    fftw=$(echo "$deps"/install/fftw-*/lib)
    set -- -DCP2K_USE_MPI=ON -DCP2K_SCALAPACK_VENDOR=GENERIC
elif [ "$mpi" = none ]; then
    prefix=$WISE_PREFIX
    fftw=$WISE_PREFIX/lib
    set -- -DCP2K_USE_MPI=OFF
else
    prefix=$WISE_PREFIX
    fftw=$WISE_PREFIX/lib
    set -- -DCP2K_USE_MPI=ON -DCP2K_SCALAPACK_VENDOR=GENERIC -DMPI_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DMPI_CXX_COMPILER="$WISE_MPI_ROOT/bin/mpicxx" \
        -DMPI_Fortran_COMPILER="$WISE_MPI_ROOT/bin/mpifort"
fi

set -- "$@" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCP2K_USE_LIBXC=ON -DCP2K_USE_LIBINT2=ON -DCP2K_USE_FFTW3=ON -DCP2K_USE_LIBXS=ON -DCP2K_USE_LIBXSMM=ON \
    -DCP2K_BLAS_VENDOR=OpenBLAS
[ "$elpa" != true ] || set -- "$@" -DCP2K_USE_ELPA=ON
[ "$hdf5" != true ] || set -- "$@" -DCP2K_USE_HDF5=ON
[ "$large" != true ] || set -- "$@" -DCP2K_USE_COSMA=ON -DCP2K_USE_SPLA=ON -DCP2K_USE_SIRIUS=ON \
    -DCP2K_USE_SPGLIB=ON -DCP2K_USE_VORI=ON
case $gpu in
    '') ;;
    RTXPRO5000) set -- "$@" -DCP2K_USE_ACCEL=CUDA -DCMAKE_CUDA_ARCHITECTURES:STRING=120 ;;
    *) set -- "$@" -DCP2K_USE_ACCEL=CUDA -DCP2K_WITH_GPU="$gpu" ;;
esac
[ -z "$gpu" ] || [ "$large" != true ] || set -- "$@" -DCP2K_USE_SPLA_GEMM_OFFLOADING=ON
# cmakeArgs is a space separated list by contract; no globbing while it is split.
set -f
# shellcheck disable=SC2086
set -- "$@" ${CMAKEARGS:-}
set +f
# SIRIUS's package looks for libfftw3_mpi without a hint.
CMAKE_LIBRARY_PATH="$fftw" bash -c '. "$1/install/setup" && shift && cmake "$@"' sh "$deps" -S "$work/src" -B "$work/build" "$@"
cache=$work/build/CMakeCache.txt
# The toolchain links COSMA and SIRIUS statically, and CMake silently drops an option whose dependency is
# off: check what will actually be built.
for option in $([ "$mpi" = none ] || echo MPI) LIBXC LIBINT2 FFTW3 LIBXS LIBXSMM $([ "$elpa" != true ] || echo ELPA) \
    $([ "$hdf5" != true ] || echo HDF5) $([ "$large" != true ] || echo COSMA SPLA SIRIUS SPGLIB VORI); do
    grep -q "^CP2K_USE_$option:BOOL=ON$" "$cache" || wise_fail "CP2K_USE_$option is off"
done
if [ -n "$gpu" ]; then
    [ "$gpu" != RTXPRO5000 ] || grep -qx 'CMAKE_CUDA_ARCHITECTURES:STRING=120' "$cache" \
        || wise_fail "CP2K must build native RTX PRO 5000 Blackwell device code"
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
cmake --build "$work/build" -j"$(wise_build_jobs)"
cmake --install "$work/build" --strip
if cp2k_gnu_stack; then
    . "$(dirname "$0")/gnu-run.sh"
    cp2k_gnu_install_commands "$deps" "$prefix"
elif [ "$mpi" = none ]; then
    ldconfig
    ! grep -q '^CP2K_USE_MPI:BOOL=ON$' "$cache" || wise_fail "the image has no MPI"
    wise_linked "$WISE_PREFIX/bin/cp2k.ssmp" "$WISE_PREFIX/lib/libfftw3" libgomp
    wise_not_linked "$WISE_PREFIX/bin/cp2k.ssmp" libmpi
else
    ldconfig
    bin=$WISE_PREFIX/bin/cp2k.psmp
    wise_mpi_linked "$bin" "$WISE_PREFIX/lib/libfftw3" "$WISE_PREFIX/lib/libscalapack"
    [ "$elpa" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libelpa_openmp"
    [ "$hdf5" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libhdf5"
fi
wise_done
