#!/bin/sh
set -eu

feature=quantum-espresso
cc=${CUDACC:-}
[ -x /opt/wise/bin/mpicc ] || { echo "$feature: the delivery must select an MPI Feature (openmpi or mpich)" >&2; exit 1; }
if [ -n "$cc" ] && ! command -v nvfortran >/dev/null; then
    echo "quantum-espresso: cudaCC=$cc needs the CUDA base image with the NVIDIA HPC SDK" >&2; exit 1
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
fetch https://gitlab.com/QEF/q-e.git 9f93ddec427d2b9a45bb72d828c6d324f62fcabd "$work/src"
git -C "$work/src" submodule update --quiet --init --depth 1 external/mbd external/devxlib

set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/wise -DCMAKE_PREFIX_PATH=/opt/wise \
    -DCMAKE_C_COMPILER=/opt/wise/bin/mpicc -DCMAKE_Fortran_COMPILER=/opt/wise/bin/mpifort \
    -DQE_ENABLE_MPI=ON -DQE_ENABLE_OPENMP=ON -DQE_FFTW_VENDOR=FFTW3
if [ -n "$cc" ]; then
    # The MPI wrappers drive the SDK compilers; QE then uses mpif.h, which is compiler neutral.
    export OMPI_CC=nvc OMPI_FC=nvfortran MPICH_CC=nvc MPICH_FC=nvfortran
    set -- "$@" -DQE_ENABLE_CUDA=ON -DQE_ENABLE_OPENACC=ON -DNVFORTRAN_CUDA_CC="$cc" \
        -DQE_ENABLE_SCALAPACK=OFF
else
    set -- "$@" -DQE_ENABLE_SCALAPACK=ON -DSCALAPACK_LIBRARIES=/opt/wise/lib/libscalapack.so
fi
cmake -S "$work/src" -B "$work/build" "$@"
cmake --build "$work/build" -j"$(nproc)"
cmake --install "$work/build"
for exe in pw.x ph.x pw2wannier90.x; do
    linked "/opt/wise/bin/$exe" /opt/wise/lib/libmpi
    if [ -n "$cc" ]; then linked "/opt/wise/bin/$exe" libcufft; else linked "/opt/wise/bin/$exe" /opt/wise/lib/libfftw3 /opt/wise/lib/libscalapack; fi
done
