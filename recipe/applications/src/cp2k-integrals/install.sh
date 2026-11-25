#!/bin/sh
set -eu
wise_id=cp2k-integrals
. /opt/wise/lib/wise/feature.sh

wise_provide cp2k-integrals
wise_require_capability mpi
wise_require fftw
wise_require scalapack
wise_apt wget unzip
wise_workdir
work=$WISE_WORK
commit=67b5da876dd6a76b8b021d5a04d1c81ba79a4c50
wise_fetch_git https://github.com/cp2k/cp2k.git "$commit" "$work/src"

# CP2K's toolchain (each download checksum-verified by it) skips what it already installed: libint and libxc take
# most of its time, so they are built first and the cp2k-toolchain Feature continues in the same tree.
deps=$WISE_PREFIX/cp2k-deps
mkdir -p "$deps"
cp -R "$work/src/tools/toolchain/." "$deps/"
mpi=$(wise_provider mpi)
gcc=system
# The toolchain's own -mtune=<target-cpu> leaves the instruction set at plain x86-64.
sed -i 's/-mtune=${TARGET_CPU}/-march=x86-64-v3 -mtune=generic/' "$deps/scripts/stage0/setup_buildtools.sh"
if wise_cuda; then
    wise_nvfortran_env
    # The static libraries end up in the shared libcp2k.
    for flags in CFLAGS CXXFLAGS FFLAGS FCFLAGS F77FLAGS F90FLAGS; do eval "export $flags=\"\$$flags -fPIC\""; done
    gcc=no
    # Keep the exported NVHPC flags instead of the GNU defaults in the pinned toolchain.
    sed -i '/^# Setup compiler flags/,/^export LDFLAGS=/c\export LDFLAGS="${TSANFLAGS}"' \
        "$deps/scripts/stage0/setup_buildtools.sh"
    sed -i 's/ -g1"/ -g"/g' "$deps/scripts/stage3/install_libint.sh"
fi
set -- --target-cpu=haswell --with-gcc="$gcc" --with-cmake=system --with-"$mpi"=system --with-fftw=system \
    --with-openblas=system --with-scalapack=system --with-libxc=install --with-libint=install \
    --with-libxs=no --with-libxsmm=no --with-dbcsr=no --with-plumed=no --with-tblite=no --with-elpa=no --with-hdf5=no \
    --with-cosma=no --with-spfft=no --with-spla=no --with-sirius=no --with-gsl=no --with-spglib=no --with-libvori=no
# The toolchain downloads with wget, which gives up on HTTP errors and refused connections.
printf '%s\n' 'tries = 5' 'waitretry = 30' 'timeout = 60' 'retry_connrefused = on' \
    'retry_on_http_error = 429,500,502,503,504' > "$deps/wgetrc"
(cd "$deps" && WGETRC="$deps/wgetrc" CPATH="$WISE_PREFIX/include" LIBRARY_PATH="$WISE_PREFIX/lib" \
    ./install_cp2k_toolchain.sh -j "$(nproc)" "$@")
for library in libint libxc; do
    ls "$deps/install/$library"-*/install_successful >/dev/null || wise_fail "$library was not built"
done
rm -rf "$deps/build"
echo "commit=$commit" > "$deps/wise.env"
wise_done
