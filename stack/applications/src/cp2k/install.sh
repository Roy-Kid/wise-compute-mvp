#!/bin/sh
set -eu

feature=cp2k
gpu=${GPUVERSION:-}
[ -x /opt/wise/bin/mpicc ] || { echo "$feature: the delivery must select an MPI Feature (openmpi or mpich)" >&2; exit 1; }
if [ -n "$gpu" ] && [ -z "${CUDA_HOME:-}" ]; then
    echo "cp2k: gpuVersion=$gpu needs the CUDA base image (CUDA_HOME is unset)" >&2; exit 1
fi
# Fetch exactly one pinned commit: no history, no tags.
fetch() { # url commit dir
    git init --quiet "$3"
    git -C "$3" fetch --quiet --depth 1 --no-tags "$1" "$2"
    git -C "$3" checkout --quiet FETCH_HEAD
}
linked() { # binary pattern...
    libs=$(ldd "$1")
    if echo "$libs" | grep -q "not found"; then echo "$libs" >&2; exit 1; fi
    bin=$1; shift
    for pattern; do
        echo "$libs" | grep -q "$pattern" || { echo "$feature: $bin does not link $pattern" >&2; exit 1; }
    done
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch https://github.com/cp2k/cp2k.git 67b5da876dd6a76b8b021d5a04d1c81ba79a4c50 "$work/src"
git -C "$work/src" submodule update --quiet --init --depth 1

# CP2K's toolchain builds the CP2K-specific libraries (each download checksum-verified by the toolchain)
# and finds MPI, FFTW, ScaLAPACK and OpenBLAS from the infra tier. Its install tree stays in the image.
deps=/opt/wise/cp2k-deps
mkdir -p "$deps"
cp -R "$work/src/tools/toolchain/." "$deps/"
mpi=openmpi
[ ! -x /opt/wise/bin/mpichversion ] || mpi=mpich
set -- --with-gcc=system --with-cmake=system --with-"$mpi"=system --with-fftw=system \
    --with-openblas=system --with-scalapack=system --with-libxc=install --with-libint=install \
    --with-libxsmm=install --with-dbcsr=install --with-elpa=no --with-cosma=no --with-sirius=no \
    --with-spglib=no --with-libvori=no --with-hdf5=no --with-plumed=no --with-gsl=no
[ -z "$gpu" ] || set -- "$@" --enable-cuda --gpu-ver="$gpu"
(cd "$deps" && CPATH=/opt/wise/include LIBRARY_PATH=/opt/wise/lib PKG_CONFIG_PATH=/opt/wise/lib/pkgconfig \
    ./install_cp2k_toolchain.sh -j "$(nproc)" "$@")
rm -rf "$deps/build"

set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/wise \
    -DCP2K_USE_MPI=ON -DCP2K_USE_LIBXC=ON -DCP2K_USE_LIBINT2=ON -DCP2K_USE_FFTW3=ON -DCP2K_USE_LIBXSMM=ON \
    -DCP2K_BLAS_VENDOR=OpenBLAS -DCP2K_SCALAPACK_VENDOR=GENERIC
[ -z "$gpu" ] || set -- "$@" -DCP2K_USE_ACCEL=CUDA -DCP2K_WITH_GPU="$gpu"
bash -c '. "$1/install/setup" && shift && cmake "$@"' sh "$deps" -S "$work/src" -B "$work/build" "$@"
cmake --build "$work/build" -j"$(nproc)"
cmake --install "$work/build"
find "$deps/install" -maxdepth 2 -type d \( -name lib -o -name lib64 \) > /etc/ld.so.conf.d/wise-cp2k.conf
ldconfig
linked /opt/wise/bin/cp2k.psmp /opt/wise/lib/libmpi /opt/wise/lib/libfftw3 /opt/wise/lib/libscalapack
[ -z "$gpu" ] || linked /opt/wise/bin/cp2k.psmp libcudart
