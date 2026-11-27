#!/bin/sh
set -eu
wise_id=cp2k-integrals
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_provide cp2k-integrals
. "$(dirname "$0")/gnu-stack.sh"
# Without an MPI in the image CP2K is the threaded cp2k.ssmp; the later CP2K Features follow.
mpi=none
if cp2k_gnu_stack; then
    mpi=own
elif wise_mpi; then
    mpi=$(wise_provider mpi)
    wise_require scalapack
fi
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
# The later CP2K Features build in the same environment.
cp "$(dirname "$0")/gnu-stack.sh" "$deps/gnu-stack.sh"
# Without DBCSR its step filters an empty file, and grep's "no lines" status would end the toolchain.
sed -i '/^  grep -v .*"$source_file" >> "$target_file"$/s/$/ || :/' "$deps/scripts/tool_kit.sh"
# The toolchain's own -mtune=<target-cpu> leaves the instruction set at plain x86-64.
sed -i 's/-mtune=${TARGET_CPU}/-march=x86-64-v3 -mtune=generic/' "$deps/scripts/stage0/setup_buildtools.sh"
if cp2k_gnu_stack; then
    cp2k_gnu_env
    # shellcheck disable=SC2046
    set -- $(cp2k_gnu_toolchain_args)
else
    if [ "$mpi" = none ]; then set -- --mpi-mode=no --with-scalapack=no
    else set -- --with-"$mpi"=system --with-scalapack=system; fi
    set -- "$@" --with-fftw=system --with-openblas=system
    export CPATH="$WISE_PREFIX/include" LIBRARY_PATH="$WISE_PREFIX/lib"
fi
set -- --target-cpu=haswell --with-gcc=system --with-cmake=system "$@" --with-libxc=install --with-libint=install \
    --with-libxs=no --with-libxsmm=no --with-dbcsr=no --with-plumed=no --with-tblite=no --with-elpa=no --with-hdf5=no \
    --with-cosma=no --with-spfft=no --with-spla=no --with-sirius=no --with-gsl=no --with-spglib=no --with-libvori=no
# The toolchain downloads with wget, which gives up on HTTP errors and refused connections.
printf '%s\n' 'tries = 5' 'waitretry = 30' 'timeout = 60' 'retry_connrefused = on' \
    'retry_on_http_error = 429,500,502,503,504' > "$deps/wgetrc"
(cd "$deps" && WGETRC="$deps/wgetrc" ./install_cp2k_toolchain.sh -j "$(wise_build_jobs)" "$@")
for library in libint libxc; do
    ls "$deps/install/$library"-*/install_successful >/dev/null || wise_fail "$library was not built"
done
rm -rf "$deps/build"
printf '%s\n' "commit=$commit" "mpi=$mpi" > "$deps/wise.env"
wise_done
