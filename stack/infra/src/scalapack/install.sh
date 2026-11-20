#!/bin/sh
set -eu

[ -x /opt/wise/bin/mpicc ] || { echo "scalapack: install an MPI Feature (openmpi or mpich) first" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
curl --fail --location --silent --show-error --retry 3 --proto '=https' \
    https://github.com/Reference-ScaLAPACK/scalapack/archive/refs/tags/v2.2.3.tar.gz -o src.tar.gz
echo "5d93701eca663925e98010dd8d0f45fd79b2191d74e5afa5711d587370a8b9dd  src.tar.gz" | sha256sum --check
tar -xzf src.tar.gz --strip-components=1
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/wise \
    -DBUILD_SHARED_LIBS=ON -DSCALAPACK_BUILD_TESTS=OFF \
    -DCMAKE_C_COMPILER=/opt/wise/bin/mpicc -DCMAKE_Fortran_COMPILER=/opt/wise/bin/mpifort
cmake --build build -j"$(nproc)"
cmake --install build
ldconfig
