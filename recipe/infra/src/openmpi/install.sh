#!/bin/sh
set -eu
wise_id=openmpi
. /usr/local/lib/devcontainer-features/feature.sh

wise_require ucx
wise_require libfabric
# One MPI per image: openmpi and mpich both claim the mpi capability.
wise_provide mpi
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-5.0.11.tar.bz2 \
    e668a3c4acd50c41dc204c8a6dd98a611e0f26af89cf677577fa9be8a2698003 src
cd src
fc=gfortran
if wise_cuda; then
    fc=nvfortran
    export FFLAGS="-O2 -tp=haswell" FCFLAGS="-O2 -tp=haswell"
fi
set -- --prefix="$WISE_PREFIX" --disable-static CC=gcc CXX=g++ FC="$fc" \
    --with-hwloc=internal --with-libevent=internal --with-pmix=internal --with-prrte=internal \
    --with-ucx="$WISE_PREFIX" --with-ofi="$WISE_PREFIX"
if wise_cuda; then set -- "$@" --with-cuda="$CUDA_HOME" --with-cuda-libdir="$CUDA_HOME/lib64/stubs"; fi
./configure "$@"
make -j"$(nproc)"
make install-strip
ldconfig
info=$("$WISE_PREFIX/bin/ompi_info" --parsable --all)
expected=false
if wise_cuda; then expected=true; fi
echo "$info" | grep -Eq "(^|:)mpi_built_with_cuda_support:value:$expected$" || wise_fail "CUDA support is not $expected"
for component in pml:ucx osc:ucx mtl:ofi btl:ofi; do
    echo "$info" | grep -q "^mca:${component%%:*}:${component#*:}:" || wise_fail "component $component was not built"
done
wise_done
