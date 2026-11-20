#!/bin/sh
set -eu

if [ -e /opt/wise/bin/mpicc ]; then echo "mpich: another MPI is already installed in /opt/wise" >&2; exit 1; fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
curl --fail --location --silent --show-error --retry 3 --proto '=https' \
    https://www.mpich.org/static/downloads/4.3.2/mpich-4.3.2.tar.gz -o src.tar.gz
echo "47d774587a7156a53752218c811c852e70ac44db9c502dc3f399b4cb817e3818  src.tar.gz" | sha256sum --check
tar -xzf src.tar.gz --strip-components=1

set -- --prefix=/opt/wise --disable-static CC=gcc CXX=g++ FC=gfortran
if [ -n "${CUDA_HOME:-}" ]; then set -- "$@" --with-cuda="$CUDA_HOME"; fi
./configure "$@"
make -j"$(nproc)" install
ldconfig
