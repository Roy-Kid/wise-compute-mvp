#!/bin/sh
set -eu
wise_id=gromacs
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

variant=${VARIANT:-cpu}
case "$variant" in
    cpu) ;;
    cuda) wise_cuda || wise_fail "variant=cuda needs the CUDA base image" ;;
    *) wise_fail "unknown variant $variant" ;;
esac
wise_workdir
src=$WISE_WORK/src
wise_fetch_git https://github.com/gromacs/gromacs.git 6c69f720aa7378fddfee67f99d51aff21ccfb0a2 "$src"

# Mixed precision on the single-precision FFTW; nothing is downloaded and no optional library is picked up by chance.
set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
    -DGMX_SIMD=AVX2_256 -DGMX_OPENMP=ON -DGMX_DOUBLE=OFF \
    -DGMX_FFT_LIBRARY=fftw3 -DGMX_BUILD_OWN_FFTW=OFF -DGMX_EXTERNAL_BLAS=ON -DGMX_EXTERNAL_LAPACK=ON \
    -DGMX_HWLOC=OFF -DGMX_USE_HDF5=OFF -DGMXAPI=OFF -DGMX_INSTALL_NBLIB_API=OFF -DGMX_PYTHON_PACKAGE=OFF
if [ "$variant" = cuda ]; then
    # The HPC SDK keeps cuFFT outside the CUDA directory. gmx needs the CUDA driver, which the SDK supplies on GPU-less builders.
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$CUDA_HOME/compat"
    set -- "$@" -DGMX_GPU=CUDA -DCUDAToolkit_ROOT="$CUDA_HOME" -DCMAKE_PREFIX_PATH="${NVHPC_ROOT:?}/math_libs;$WISE_PREFIX"
else
    set -- "$@" -DGMX_GPU=OFF -DCMAKE_PREFIX_PATH="$WISE_PREFIX"
fi
# cmakeArgs is a space separated list by contract; no globbing while it is split.
set -f
# shellcheck disable=SC2086
set -- "$@" ${CMAKEARGS:-}
set +f
build() { # directory program mpi-arguments...
    dir=$WISE_WORK/$1 program=$2; shift 2
    cmake -S "$src" -B "$dir" "$@"
    # Whatever the options said (cmakeArgs included), check what will actually be built.
    cache=$dir/CMakeCache.txt
    grep -q '^GMX_FFT_LIBRARY:STRING=fftw3$' "$cache" || wise_fail "GROMACS must use FFTW from the fftw Feature"
    grep -q '^GMX_BUILD_OWN_FFTW:BOOL=OFF$' "$cache" || wise_fail "GROMACS must not download FFTW"
    gpu=$(sed -n 's/^GMX_GPU:STRING=//p' "$cache")
    if [ "$variant" = cuda ]; then [ "$gpu" = CUDA ] || wise_fail "variant=cuda needs GMX_GPU=CUDA, not $gpu"
    else [ "$gpu" = OFF ] || wise_fail "variant=cpu builds no GPU kernels"; fi
    cmake --build "$dir" -j"$(wise_build_jobs)"
    cmake --install "$dir" --strip
    ldconfig
    wise_linked "$WISE_PREFIX/bin/$program" libgomp libopenblas
    # GROMACS finds its libraries relative to the program, so ldd prints a path through bin/../lib.
    fftw=$(ldd "$WISE_PREFIX/bin/$program" | awk '$1 ~ /^libfftw3f[.]so/ { print $3 }')
    [ -n "$fftw" ] && [ "$(readlink -f "$fftw")" = "$(readlink -f "$WISE_PREFIX/lib/libfftw3f.so")" ] \
        || wise_fail "$program does not link the FFTW of the fftw Feature"
    [ "$variant" != cuda ] || wise_linked "$WISE_PREFIX/bin/$program" libcufft
}
# gmx: every tool and a thread-MPI mdrun, the fastest choice on one node.
build threads gmx "$@" -DGMX_MPI=OFF -DGMX_THREAD_MPI=ON
wise_not_linked "$WISE_PREFIX/bin/gmx" 'libmpi'
if wise_mpi; then
    # gmx_mpi: the same program on the image's MPI, for runs across nodes and multi-simulations.
    build mpi gmx_mpi "$@" -DGMX_MPI=ON -DMPI_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DMPI_CXX_COMPILER="$WISE_MPI_ROOT/bin/mpicxx"
    wise_mpi_linked "$WISE_PREFIX/bin/gmx_mpi"
fi
wise_done
