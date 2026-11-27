#!/bin/sh
set -eu
wise_id=dftbplus
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_workdir
# The release source archive holds every external project, so the build fetches nothing.
wise_fetch_tar https://github.com/dftbplus/dftbplus/releases/download/26.1/dftbplus-26.1.tar.xz \
    0b370b7070c1bedd276906f8de2ebd95f1f90e75909f0766af895fa057924171 "$WISE_WORK/src"
# The threaded build has every feature of DFTB+ and no MPI; GCC builds it on every base image.
# Many-body dispersion stays off: the libMBD in this archive configures only inside its Git repository.
cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DCMAKE_Fortran_COMPILER=gfortran \
    -DBLA_VENDOR=OpenBLAS -DBUILD_SHARED_LIBS=ON -DHYBRID_CONFIG_METHODS=Submodule -DTEST_DOWNLOAD_DATA=OFF \
    -DWITH_OMP=ON -DWITH_MPI=OFF -DWITH_GPU=OFF -DWITH_TBLITE=ON -DWITH_SDFTD3=ON -DWITH_MBD=OFF \
    -DWITH_TRANSPORT=ON -DWITH_SOCKETS=ON -DWITH_API=ON -DWITH_PYTHON=OFF
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build"
ldconfig
wise_linked "$WISE_PREFIX/bin/dftb+" libopenblas libgomp
wise_not_linked "$WISE_PREFIX/bin/dftb+" libmpi
wise_done
