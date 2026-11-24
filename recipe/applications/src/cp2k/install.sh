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
wise_apt wget unzip
wise_workdir
work=$WISE_WORK
wise_fetch_git https://github.com/cp2k/cp2k.git 67b5da876dd6a76b8b021d5a04d1c81ba79a4c50 "$work/src" --all

# CP2K's toolchain builds the CP2K-specific libraries (each download checksum-verified by the toolchain)
# and finds MPI, FFTW, ScaLAPACK, OpenBLAS, ELPA and HDF5 from the infra tier. Its install tree stays in the
# image.
deps=$WISE_PREFIX/cp2k-deps
mkdir -p "$deps"
cp -R "$work/src/tools/toolchain/." "$deps/"
mpi=$(wise_provider mpi)
gcc=system
# The toolchain's own -mtune=<target-cpu> leaves the instruction set at plain x86-64.
sed -i 's/-mtune=${TARGET_CPU}/-march=x86-64-v3 -mtune=generic/' "$deps/scripts/stage0/setup_buildtools.sh"
sed -i 's/-mtune=native/-mtune=generic/g' "$deps/scripts/stage8/install_sirius.sh"
# CP2K tunes its Release build for the build machine.
native=$work/src/cmake/CompilerConfiguration.cmake
sed -i 's/"-m[a-z]*=native;-mtune=native"/"-march=x86-64-v3;-mtune=generic"/' "$native"
grep -q '"-march=x86-64-v3;-mtune=generic"' "$native" || wise_fail "CP2K's native tuning was not replaced"
if wise_cuda; then
    wise_nvfortran_env
    # The static libraries end up in the shared libcp2k.
    for flags in CFLAGS CXXFLAGS FFLAGS FCFLAGS F77FLAGS F90FLAGS; do eval "export $flags=\"\$$flags -fPIC\""; done
    gcc=no
    # Keep the exported NVHPC flags instead of the GNU defaults in the pinned toolchain.
    sed -i '/^# Setup compiler flags/,/^export LDFLAGS=/c\export LDFLAGS="${TSANFLAGS}"' \
        "$deps/scripts/stage0/setup_buildtools.sh"
    sed -i 's/-mtune=generic -ftree-loop-vectorize/-tp=haswell/g' "$deps/scripts/stage8/install_sirius.sh"
    sed -i 's/ -g1"/ -g"/g' "$deps/scripts/stage3/install_libint.sh"
    sed -i 's/ -fpermissive"/"/' "$deps/scripts/stage7/install_libvdwxc.sh"
fi
if [ -n "$gpu" ]; then
    # The toolchain builds SpFFT, SPLA and SIRIUS twice and lets CP2K find the CPU builds. Build each once, with
    # CUDA; these builds run on the host too.
    stage8=$deps/scripts/stage8
    cuda='-DCMAKE_CUDA_ARCHITECTURES=${ARCH_NUM} -DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler'
    sed -i "s/-DSPFFT_STATIC=ON/& -DSPFFT_GPU_BACKEND=CUDA $cuda/" "$stage8/install_spfft.sh"
    sed -i 's/-DSPLA_STATIC=ON/& -DSPLA_GPU_BACKEND=CUDA/' "$stage8/install_spla.sh"
    sed -i "s/-DSIRIUS_USE_PUGIXML=ON/& -DSIRIUS_USE_CUDA=ON $cuda/" "$stage8/install_sirius.sh"
    # SIRIUS's package still asks for the FindCUDA module that CMake removed; its cudalibs target finds CUDAToolkit.
    sed -i '/^ *cd SIRIUS-/a sed -i "/find_dependency(CUDA /d" cmake/sirius_cxxConfig.cmake.in' "$stage8/install_sirius.sh"
    for library in spfft spla sirius; do
        sed -i 's/\[ "$ENABLE_CUDA" = "__TRUE__" \]/false/' "$stage8/install_$library.sh"
    done
fi
pick() { if [ "$1" = true ]; then echo "$2"; else echo no; fi; }
set -- --target-cpu=haswell --with-gcc="$gcc" --with-cmake=system --with-"$mpi"=system --with-fftw=system \
    --with-openblas=system --with-scalapack=system --with-libxc=install --with-libint=install \
    --with-libxs=install --with-libxsmm=install --with-dbcsr=install --with-plumed=no --with-tblite=no \
    --with-elpa="$(pick "$elpa" system)" --with-hdf5="$(pick "$hdf5" system)" \
    --with-cosma="$(pick "$large" install)" --with-spfft="$(pick "$large" install)" --with-spla="$(pick "$large" install)" \
    --with-sirius="$(pick "$large" install)" --with-gsl="$(pick "$large" install)" \
    --with-spglib="$(pick "$large" install)" --with-libvori="$(pick "$large" install)"
[ -z "$gpu" ] || set -- "$@" --enable-cuda --gpu-ver="$gpu"
# The toolchain downloads with wget, which gives up on HTTP errors and refused connections.
printf '%s\n' 'tries = 5' 'waitretry = 30' 'timeout = 60' 'retry_connrefused = on' \
    'retry_on_http_error = 429,500,502,503,504' > "$work/wgetrc"
(cd "$deps" && WGETRC="$work/wgetrc" CPATH="$WISE_PREFIX/include" LIBRARY_PATH="$WISE_PREFIX/lib" \
    ./install_cp2k_toolchain.sh -j "$(nproc)" "$@")
rm -rf "$deps/build"

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
bash -c '. "$1/install/setup" && shift && cmake "$@"' sh "$deps" -S "$work/src" -B "$work/build" "$@"
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
find "$deps/install" -maxdepth 2 -type d \( -name lib -o -name lib64 \) > /etc/ld.so.conf.d/wise-cp2k.conf
ldconfig
bin=$WISE_PREFIX/bin/cp2k.psmp
wise_mpi_linked "$bin" "$WISE_PREFIX/lib/libfftw3" "$WISE_PREFIX/lib/libscalapack"
[ "$elpa" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libelpa_openmp"
[ "$hdf5" != true ] || wise_linked "$bin" "$WISE_PREFIX/lib/libhdf5"
[ -z "$gpu" ] || wise_linked "$bin" libcudart
wise_done
