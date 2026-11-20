#!/bin/sh
set -eu

[ -x /opt/wise/bin/mpicc ] || { echo "linear-algebra: install an MPI Feature (openmpi or mpich) first" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends libopenblas-openmp-dev
rm -rf /var/lib/apt/lists/*
for lib in libblas.so.3 liblapack.so.3; do
    readlink -f "/usr/lib/x86_64-linux-gnu/$lib" | grep -q openblas-openmp \
        || { echo "linear-algebra: $lib does not resolve to OpenBLAS (OpenMP)" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
curl --fail --location --silent --show-error --retry 3 --proto '=https' \
    https://www.fftw.org/fftw-3.3.11.tar.gz -o src.tar.gz
echo "5630c24cdeb33b131612f7eb4b1a9934234754f9f388ff8617458d0be6f239a1  src.tar.gz" | sha256sum --check
tar -xzf src.tar.gz --strip-components=1
# SIMD kernels are chosen at run time, so the build stays portable across x86-64 CPUs.
./configure --prefix=/opt/wise --enable-shared --disable-static CC=gcc MPICC=/opt/wise/bin/mpicc \
    --enable-mpi --enable-openmp --enable-threads --enable-sse2 --enable-avx --enable-avx2
make -j"$(nproc)" install
ldconfig
