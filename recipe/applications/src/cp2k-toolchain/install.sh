#!/bin/sh
set -eu
wise_id=cp2k-toolchain
. /opt/wise/lib/wise/feature.sh

wise_provide cp2k-toolchain
wise_require_capability mpi
wise_require fftw
wise_require scalapack
gpu=${GPUVERSION:-}
elpa=${ELPA:-false}
hdf5=${HDF5:-false}
large=${LARGESYSTEMS:-false}
[ -z "$gpu" ] || wise_cuda || wise_fail "gpuVersion=$gpu needs the CUDA base image"
case $gpu in *[!A-Za-z0-9]*) wise_fail "gpuVersion=$gpu is no GPU name" ;; esac
wise_require_if "$elpa" elpa "elpa=true"
wise_require_if "$hdf5" hdf5 "hdf5=true"
wise_require_if "$large" hdf5 "largeSystems=true (SIRIUS)"
[ "$large" != true ] || [ "$hdf5" = true ] || wise_fail "largeSystems=true needs hdf5=true (SIRIUS)"
wise_apt wget unzip
wise_workdir
work=$WISE_WORK
commit=67b5da876dd6a76b8b021d5a04d1c81ba79a4c50
wise_fetch_git https://github.com/cp2k/cp2k.git "$commit" "$work/src"

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
find "$deps/install" -maxdepth 2 -type d \( -name lib -o -name lib64 \) > /etc/ld.so.conf.d/wise-cp2k.conf
# The cp2k Feature builds this commit with these choices.
printf '%s\n' "commit=$commit" "gpu='$gpu'" "elpa=$elpa" "hdf5=$hdf5" "large=$large" > "$deps/wise.env"
wise_done
