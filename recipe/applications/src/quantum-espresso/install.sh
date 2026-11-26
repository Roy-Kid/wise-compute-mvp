#!/bin/sh
set -eu
wise_id=quantum-espresso
. /usr/local/lib/devcontainer-features/feature.sh

wise_require fftw
# Without an MPI in the image QE is the threaded program: no ScaLAPACK, ELPA or parallel HDF5.
if wise_mpi; then
    wise_require scalapack
else
    [ -z "${CUDACC:-}" ] && [ "${ELPA:-false}" != true ] && [ "${HDF5:-false}" != true ] \
        || wise_fail "cudaCC, elpa and hdf5 need an MPI in the image"
fi
cc=$(echo "${CUDACC:-}" | tr -d ' ')
wise_require_if "${ELPA:-false}" elpa "elpa=true"
wise_require_if "${HDF5:-false}" hdf5 "hdf5=true"
if [ -n "$cc" ]; then
    wise_cuda || wise_fail "cudaCC needs the CUDA base image"
    . "$(dirname "$0")/qe-cuda.sh"
    architectures=$(qe_cuda_architectures "$cc") || wise_fail "cudaCC must be comma-separated compute capabilities"
fi
wise_workdir
wise_fetch_git https://gitlab.com/QEF/q-e.git 9f93ddec427d2b9a45bb72d828c6d324f62fcabd "$WISE_WORK/src" external/mbd external/devxlib

if wise_cuda; then wise_nvfortran_env; fi
set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DCMAKE_PREFIX_PATH="$WISE_PREFIX" -DQE_FFTW_VENDOR=FFTW3 -DBLA_VENDOR=OpenBLAS
if wise_mpi; then
    set -- "$@" -DCMAKE_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DCMAKE_Fortran_COMPILER="$WISE_MPI_ROOT/bin/mpifort" \
        -DQE_ENABLE_MPI=ON -DQE_ENABLE_SCALAPACK=ON -DSCALAPACK_LIBRARIES="$WISE_PREFIX/lib/libscalapack.so"
else
    set -- "$@" -DCMAKE_C_COMPILER=gcc -DCMAKE_Fortran_COMPILER=gfortran -DQE_ENABLE_MPI=OFF
fi
if [ -n "$cc" ]; then
    set -- "$@" \
        -DFFTW3_LIBRARIES="$WISE_PREFIX/lib/libfftw3.so" -DFFTW3_INCLUDE_DIRS="$WISE_PREFIX/include"
else
    set -- "$@" -DQE_ENABLE_OPENMP=ON
fi
if [ "${ELPA:-false}" = true ]; then
    elpa_version=$(pkg-config --modversion elpa_openmp)
    elpa_include=$(pkg-config --variable=includedir elpa_openmp)/elpa_openmp-$elpa_version
    elpa_libdir=$(pkg-config --variable=libdir elpa_openmp)
    set -- "$@" -DQE_ENABLE_ELPA=ON -DELPA_VERSION="$elpa_version" \
        -DELPA_INCLUDE_DIRS="$elpa_include" -DELPA_Fortran_MODS_DIR="$elpa_include/modules" \
        -DELPA_LIBRARIES="$elpa_libdir/libelpa_openmp.so"
fi
# HDF5 2 exports HDF5_PROVIDES_PARALLEL; CMake before 4 reads HDF5_ENABLE_PARALLEL and would pick serial I/O.
[ "${HDF5:-false}" != true ] || set -- "$@" -DQE_ENABLE_HDF5=ON -DHDF5_ROOT="$WISE_PREFIX" -DHDF5_ENABLE_PARALLEL=ON
# cmakeArgs is a space separated list by contract; no globbing while it is split.
set -f
# shellcheck disable=SC2086
set -- "$@" ${CMAKEARGS:-}
set +f
if [ -n "$cc" ]; then
    qe_cuda_cmake "$architectures" -S "$WISE_WORK/src" -B "$WISE_WORK/build" "$@"
else
    cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" "$@"
fi
if [ "${HDF5:-false}" = true ]; then
    grep -rqw -- '-D__HDF5' --include=flags.make "$WISE_WORK/build" || wise_fail "HDF5 is off"
    ! grep -rqw -- '-D__HDF5_SERIAL' --include=flags.make "$WISE_WORK/build" || wise_fail "HDF5 I/O is serial"
fi
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build" --strip
for exe in pw.x ph.x pw2wannier90.x; do
    bin=$WISE_PREFIX/bin/$exe
    if wise_mpi; then wise_mpi_linked "$bin" "$WISE_PREFIX/lib/libscalapack"; else wise_not_linked "$bin" libmpi; fi
    [ "${ELPA:-false}" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libelpa"
    [ "${HDF5:-false}" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libhdf5"
    if [ -n "$cc" ]; then wise_linked "$bin" libcufft && wise_not_linked "$bin" libgomp
    else wise_linked "$bin" "$WISE_PREFIX/lib/libfftw3"; fi
done
wise_done
