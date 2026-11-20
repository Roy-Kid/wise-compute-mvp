#!/bin/sh
set -eu

if [ -e /opt/wise/bin/mpicc ]; then echo "openmpi: another MPI is already installed in /opt/wise" >&2; exit 1; fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
curl --fail --location --silent --show-error --retry 3 --proto '=https' \
    https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-5.0.11.tar.bz2 -o src.tar.bz2
echo "e668a3c4acd50c41dc204c8a6dd98a611e0f26af89cf677577fa9be8a2698003  src.tar.bz2" | sha256sum --check
tar -xjf src.tar.bz2 --strip-components=1

# GCC builds the library and its Fortran modules even on the CUDA base, so gfortran applications can
# use the mpi modules; nvfortran codes use mpif.h through the same wrappers.
set -- --prefix=/opt/wise --disable-static CC=gcc CXX=g++ FC=gfortran \
    --with-hwloc=internal --with-libevent=internal --with-pmix=internal --with-prrte=internal
if [ -n "${CUDA_HOME:-}" ]; then
    set -- "$@" --with-cuda="$CUDA_HOME" --with-cuda-libdir="$CUDA_HOME/lib64/stubs"
fi
./configure "$@"
make -j"$(nproc)" install
ldconfig

built=$(/opt/wise/bin/ompi_info --parsable --all | sed -n 's/^mpi_built_with_cuda_support:value://p')
expected=false
[ -z "${CUDA_HOME:-}" ] || expected=true
[ "$built" = "$expected" ] || { echo "openmpi: CUDA support is $built, expected $expected" >&2; exit 1; }
