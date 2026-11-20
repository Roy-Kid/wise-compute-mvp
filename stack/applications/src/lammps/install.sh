#!/bin/sh
set -eu

feature=lammps
arch=${KOKKOSCUDAARCH:-}
[ -x /opt/wise/bin/mpicc ] || { echo "$feature: the delivery must select an MPI Feature (openmpi or mpich)" >&2; exit 1; }
if [ -n "$arch" ] && [ -z "${CUDA_HOME:-}" ]; then
    echo "lammps: kokkosCudaArch=$arch needs the CUDA base image (CUDA_HOME is unset)" >&2; exit 1
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
fetch https://github.com/lammps/lammps.git 098ffdefa525cabc82272925de02e9884f58c657 "$work/src"

set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/wise -DBUILD_SHARED_LIBS=ON \
    -DBUILD_MPI=ON -DMPI_C_COMPILER=/opt/wise/bin/mpicc -DMPI_CXX_COMPILER=/opt/wise/bin/mpicxx \
    -DBUILD_OMP=ON -DFFT=FFTW3 -DFFTW3_INCLUDE_DIR=/opt/wise/include -DFFTW3_LIBRARY=/opt/wise/lib/libfftw3.so \
    -DPKG_OPENMP=ON -DPKG_MANYBODY=ON -DPKG_KSPACE=ON -DPKG_MOLECULE=ON -DPKG_RIGID=ON -DPKG_MEAM=ON \
    -DPKG_REAXFF=ON -DPKG_REPLICA=ON -DPKG_MC=ON -DPKG_CLASS2=ON -DPKG_EXTRA-PAIR=ON \
    -DPKG_EXTRA-MOLECULE=ON -DPKG_EXTRA-FIX=ON -DPKG_EXTRA-COMPUTE=ON
if [ -n "$arch" ]; then
    # cuFFT lives in the HPC SDK's math_libs next to its cuda directory.
    set -- "$@" -DPKG_KOKKOS=ON -DKokkos_ENABLE_CUDA=ON -DKokkos_ENABLE_OPENMP=ON \
        -DKokkos_ARCH_"$arch"=ON -DFFT_KOKKOS=CUFFT -DCUDAToolkit_ROOT="$CUDA_HOME" \
        -DCMAKE_PREFIX_PATH="${NVHPC_ROOT:?}/math_libs" \
        -DCMAKE_CXX_COMPILER="$work/src/lib/kokkos/bin/nvcc_wrapper"
fi
cmake -S "$work/src/cmake" -B "$work/build" "$@"
cmake --build "$work/build" -j"$(nproc)"
cmake --install "$work/build"
ldconfig
linked /opt/wise/bin/lmp /opt/wise/lib/libmpi /opt/wise/lib/libfftw3
[ -z "$arch" ] || linked /opt/wise/bin/lmp libcufft
