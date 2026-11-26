#!/bin/sh
set -eu
wise_id=cp2k-toolchain
. /usr/local/lib/devcontainer-features/feature.sh

wise_provide cp2k-toolchain
wise_require_capability cp2k-integrals
deps=$WISE_PREFIX/cp2k-deps
# On the CUDA base CP2K has a GNU stack of its own; see the cp2k-integrals Feature.
. "$deps/gnu-stack.sh"
# commit and mpi, as the cp2k-integrals Feature chose them.
# shellcheck source=/dev/null
. "$deps/wise.env"
gpu=${GPUVERSION:-}
elpa=${ELPA:-false}
hdf5=${HDF5:-false}
large=${LARGESYSTEMS:-false}
[ -z "$gpu" ] || wise_cuda || wise_fail "gpuVersion=$gpu needs the CUDA base image"
case $gpu in *[!A-Za-z0-9]*) wise_fail "gpuVersion=$gpu is no GPU name" ;; esac
[ "$large" != true ] || [ "$hdf5" = true ] || wise_fail "largeSystems=true needs hdf5=true (SIRIUS)"
if cp2k_gnu_stack; then
    cp2k_gnu_env
    provided=install
elif [ "$mpi" = none ]; then
    [ "$elpa$hdf5$large" = falsefalsefalse ] || wise_fail "elpa, hdf5 and largeSystems need an MPI in the image"
    wise_require fftw
    provided=system
else
    wise_require_capability mpi
    wise_require fftw
    wise_require scalapack
    wise_require_if "$elpa" elpa "elpa=true"
    wise_require_if "$hdf5" hdf5 "hdf5=true"
    wise_require_if "$large" hdf5 "largeSystems=true (SIRIUS)"
    provided=system
fi

# The toolchain finds MPI, FFTW, ScaLAPACK, OpenBLAS, ELPA and HDF5 from the infra tier (in its own tree on the
# CUDA base), and libint and libxc where the cp2k-integrals Feature left them. Its install tree stays in the image.
sed -i 's/-mtune=native/-mtune=generic/g; s/-DSIRIUS_USE_PUGIXML=ON/& -DSIRIUS_BUILD_APPS=OFF/' "$deps/scripts/stage8/install_sirius.sh"
if [ "$gpu" = RTXPRO5000 ]; then
    # The pinned toolchain already has a DBCSR backport for GB10. Add the desktop Blackwell architecture
    # to the GPU model table and reuse that backport with the right architecture and parameter filename.
    entry=$deps/install_cp2k_toolchain.sh
    dbcsr=$deps/scripts/stage9/install_dbcsr.sh
    grep -q '^  GB10)' "$entry" && grep -q 'GPU_ARCH_NUMBER_GB10 121' "$dbcsr" \
        || wise_fail "CP2K toolchain GPU model tables changed"
    sed -i '/GB10 |/s/GB10 |/GB10 | RTXPRO5000 |/; s/| GB10) ;;/| GB10 | RTXPRO5000) ;;/; /^  GB10)$/i\  RTXPRO5000)\n    export ARCH_NUM="120"\n    ;;' "$entry"
    sed -i 's/GB10/RTXPRO5000/g; s/sm_121/sm_120/g; s/GPU_ARCH_NUMBER_RTXPRO5000 121/GPU_ARCH_NUMBER_RTXPRO5000 120/g' "$dbcsr"
    # Covers the CUDA CMake projects which do not pass a model-specific flag themselves.
    export CUDAARCHS=120
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
if cp2k_gnu_stack; then
    # shellcheck disable=SC2046
    set -- $(cp2k_gnu_toolchain_args)
else
    if [ "$mpi" = none ]; then set -- --mpi-mode=no --with-scalapack=no
    else set -- --with-"$mpi"=system --with-scalapack=system; fi
    set -- "$@" --with-fftw=system --with-openblas=system
    # SIRIUS looks for libfftw3_mpi without a hint.
    export CPATH="$WISE_PREFIX/include" LIBRARY_PATH="$WISE_PREFIX/lib" CMAKE_LIBRARY_PATH="$WISE_PREFIX/lib"
fi
set -- --target-cpu=haswell --with-gcc=system --with-cmake=system "$@" --with-libxc=install --with-libint=install \
    --with-libxs=install --with-libxsmm=install --with-dbcsr=install --with-plumed=no --with-tblite=no \
    --with-elpa="$(pick "$elpa" "$provided")" --with-hdf5="$(pick "$hdf5" "$provided")" \
    --with-cosma="$(pick "$large" install)" --with-spfft="$(pick "$large" install)" --with-spla="$(pick "$large" install)" \
    --with-sirius="$(pick "$large" install)" --with-gsl="$(pick "$large" install)" \
    --with-spglib="$(pick "$large" install)" --with-libvori="$(pick "$large" install)"
[ -z "$gpu" ] || set -- "$@" --enable-cuda --gpu-ver="$gpu"
(cd "$deps" && WGETRC="$deps/wgetrc" ./install_cp2k_toolchain.sh -j "$(wise_build_jobs)" "$@")
rm -rf "$deps/build"
# The GNU stack has an MPI of its own, which the loader must not offer to the rest of the image.
cp2k_gnu_stack || find "$deps/install" -maxdepth 2 -type d \( -name lib -o -name lib64 \) > /etc/ld.so.conf.d/wise-cp2k.conf
# The cp2k Feature follows these choices.
printf '%s\n' "gpu='$gpu'" "elpa=$elpa" "hdf5=$hdf5" "large=$large" >> "$deps/wise.env"
wise_done
