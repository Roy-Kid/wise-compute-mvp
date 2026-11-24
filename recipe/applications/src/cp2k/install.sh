#!/bin/sh
set -eu
wise_id=cp2k
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_require fftw
wise_require scalapack
gpu=${GPUVERSION:-}
elpa=${ELPA:-false}
hdf5=${HDF5:-false}
large=${LARGESYSTEMS:-false}
[ -z "$gpu" ] || wise_cuda || wise_fail "gpuVersion=$gpu needs the CUDA base image"
wise_require_if "$elpa" elpa "elpa=true"
wise_require_if "$hdf5" hdf5 "hdf5=true"
wise_require_if "$large" hdf5 "largeSystems=true (SIRIUS)"
[ "$large" != true ] || [ "$hdf5" = true ] || wise_fail "largeSystems=true needs hdf5=true (SIRIUS)"
wise_apt wget
wise_workdir
work=$WISE_WORK
wise_fetch_git https://github.com/cp2k/cp2k.git 67b5da876dd6a76b8b021d5a04d1c81ba79a4c50 "$work/src" --all

# CP2K's toolchain builds the CP2K-specific libraries (each download checksum-verified by the toolchain)
# and finds MPI, FFTW, ScaLAPACK, OpenBLAS, ELPA and HDF5 from the infra tier. Its install tree stays in the
# image. --target-cpu matches the x86-64-v3 baseline of the openmp Feature.
deps=$WISE_PREFIX/cp2k-deps
mkdir -p "$deps"
cp -R "$work/src/tools/toolchain/." "$deps/"
mpi=$(wise_provider mpi)
gcc=system
if wise_cuda; then
    wise_nvfortran_env
    gcc=no
    # Keep the exported NVHPC flags instead of the GNU defaults in the pinned toolchain.
    sed -i '/^# Setup compiler flags/,/^export LDFLAGS=/c\export LDFLAGS="${TSANFLAGS}"' \
        "$deps/scripts/stage0/setup_buildtools.sh"
    sed -i 's/-mtune=native -ftree-loop-vectorize/-tp=haswell/g' "$deps/scripts/stage8/install_sirius.sh"
    sed -i 's/ -g1"/ -g"/g' "$deps/scripts/stage3/install_libint.sh"
fi
pick() { if [ "$1" = true ]; then echo "$2"; else echo no; fi; }
set -- --target-cpu=haswell --with-gcc="$gcc" --with-cmake=system --with-"$mpi"=system --with-fftw=system \
    --with-openblas=system --with-scalapack=system --with-libxc=install --with-libint=install \
    --with-libxsmm=install --with-dbcsr=install --with-plumed=no \
    --with-elpa="$(pick "$elpa" system)" --with-hdf5="$(pick "$hdf5" system)" \
    --with-cosma="$(pick "$large" install)" --with-spfft="$(pick "$large" install)" --with-spla="$(pick "$large" install)" \
    --with-sirius="$(pick "$large" install)" --with-gsl="$(pick "$large" install)" \
    --with-spglib="$(pick "$large" install)" --with-libvori="$(pick "$large" install)"
[ -z "$gpu" ] || set -- "$@" --enable-cuda --gpu-ver="$gpu"
(cd "$deps" && CPATH="$WISE_PREFIX/include" LIBRARY_PATH="$WISE_PREFIX/lib" \
    ./install_cp2k_toolchain.sh -j "$(nproc)" "$@")
rm -rf "$deps/build"

set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DMPI_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DMPI_CXX_COMPILER="$WISE_MPI_ROOT/bin/mpicxx" \
    -DMPI_Fortran_COMPILER="$WISE_MPI_ROOT/bin/mpifort" \
    -DCP2K_USE_MPI=ON -DCP2K_USE_LIBXC=ON -DCP2K_USE_LIBINT2=ON -DCP2K_USE_FFTW3=ON -DCP2K_USE_LIBXSMM=ON \
    -DCP2K_BLAS_VENDOR=OpenBLAS -DCP2K_SCALAPACK_VENDOR=GENERIC
[ "$elpa" != true ] || set -- "$@" -DCP2K_USE_ELPA=ON
[ "$hdf5" != true ] || set -- "$@" -DCP2K_USE_HDF5=ON
[ "$large" != true ] || set -- "$@" -DCP2K_USE_COSMA=ON -DCP2K_USE_SPLA=ON -DCP2K_USE_SIRIUS=ON \
    -DCP2K_USE_SPGLIB=ON -DCP2K_USE_VORI=ON
[ -z "$gpu" ] || set -- "$@" -DCP2K_USE_ACCEL=CUDA -DCP2K_WITH_GPU="$gpu"
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
bash -c '. "$1/install/setup" && shift && cmake "$@"' sh "$deps" -S "$work/src" -B "$work/build" "$@"
cmake --build "$work/build" -j"$(nproc)"
cmake --install "$work/build" --strip
find "$deps/install" -maxdepth 2 -type d \( -name lib -o -name lib64 \) > /etc/ld.so.conf.d/wise-cp2k.conf
ldconfig
bin=$WISE_PREFIX/bin/cp2k.psmp
wise_mpi_linked "$bin" "$WISE_PREFIX/lib/libfftw3" "$WISE_PREFIX/lib/libscalapack"
[ "$elpa" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libelpa_openmp"
[ "$hdf5" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libhdf5"
[ "$large" != true ] || wise_linked "$bin" libcosma libsirius
[ -z "$gpu" ] || wise_linked "$bin" libcudart
wise_done
