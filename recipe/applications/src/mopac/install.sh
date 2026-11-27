#!/bin/sh
set -eu
wise_id=mopac
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_workdir
wise_fetch_git https://github.com/openmopac/mopac.git 052691223d19935a89f0fe18cd12301bd83e4201 "$WISE_WORK/src"
# MOPAC has no MPI; GCC builds it on every base image.
cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_C_COMPILER=gcc -DCMAKE_Fortran_COMPILER=gfortran -DBLA_VENDOR=OpenBLAS \
    -DAUTO_BLAS=ON -DENABLE_MKL=OFF -DTHREADS_KEYWORD=ON -DMDI=OFF -DGPU=OFF -DTESTS=OFF
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build"
ldconfig
wise_linked "$WISE_PREFIX/bin/mopac" libopenblas libgomp
wise_done
