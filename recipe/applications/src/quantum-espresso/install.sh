#!/bin/sh
set -eu
wise_id=quantum-espresso
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_require fftw
wise_require scalapack
cc=$(echo "${CUDACC:-}" | tr -d ' ')
wise_require_if "${ELPA:-false}" elpa "elpa=true"
wise_require_if "${HDF5:-false}" hdf5 "hdf5=true"
wise_workdir
wise_fetch_git https://gitlab.com/QEF/q-e.git 9f93ddec427d2b9a45bb72d828c6d324f62fcabd "$WISE_WORK/src" external/mbd external/devxlib

if wise_cuda; then wise_nvfortran_env; fi
set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DCMAKE_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DCMAKE_Fortran_COMPILER="$WISE_MPI_ROOT/bin/mpifort" \
    -DCMAKE_PREFIX_PATH="$WISE_PREFIX" -DQE_ENABLE_MPI=ON -DQE_FFTW_VENDOR=FFTW3 \
    -DBLA_VENDOR=OpenBLAS -DQE_ENABLE_SCALAPACK=ON -DSCALAPACK_LIBRARIES="$WISE_PREFIX/lib/libscalapack.so"
if [ -n "$cc" ]; then
    wise_cuda || wise_fail "cudaCC needs the CUDA base image"
    # One MPI rank per GPU with OpenACC.
    # One cc goes to QE, the others are added as -gpu=ccNN.
    more=$(echo "$cc" | tr ',' '\n' | sed '1d; s/^/-gpu=cc/' | tr '\n' ' ')
    set -- "$@" -DQE_ENABLE_CUDA=ON -DQE_ENABLE_OPENACC=ON -DQE_ENABLE_MPI_GPU_AWARE=ON -DQE_ENABLE_OPENMP=OFF \
        -DNVFORTRAN_CUDA_CC="${cc%%,*}" -DCMAKE_Fortran_FLAGS="$FFLAGS $more" \
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
[ "${HDF5:-false}" != true ] || set -- "$@" -DQE_ENABLE_HDF5=ON -DHDF5_ROOT="$WISE_PREFIX"
# cmakeArgs is a space separated list by contract; no globbing while it is split.
set -f
# shellcheck disable=SC2086
set -- "$@" ${CMAKEARGS:-}
set +f
cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" "$@"
cmake --build "$WISE_WORK/build" -j"$(nproc)"
cmake --install "$WISE_WORK/build" --strip
for exe in pw.x ph.x pw2wannier90.x; do
    bin=$WISE_PREFIX/bin/$exe
    wise_mpi_linked "$bin" "$WISE_PREFIX/lib/libscalapack"
    [ "${ELPA:-false}" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libelpa"
    [ "${HDF5:-false}" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libhdf5"
    if [ -n "$cc" ]; then wise_linked "$bin" libcufft && wise_not_linked "$bin" libgomp
    else wise_linked "$bin" "$WISE_PREFIX/lib/libfftw3"; fi
done
wise_done
