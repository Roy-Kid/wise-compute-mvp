#!/bin/sh
set -eu
wise_id=netcdf
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_require hdf5
wise_apt m4
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://github.com/Unidata/netcdf-c/archive/refs/tags/v4.10.1.tar.gz \
    33c27231c478c3b35da7c7758fbdd02da1fe407abcb16ddfe195f69d164f930d src
cd src
./configure --prefix="$WISE_PREFIX" --disable-static CC="$WISE_MPI_ROOT/bin/mpicc" \
    CPPFLAGS="-I$WISE_PREFIX/include" LDFLAGS="-L$WISE_PREFIX/lib" \
    --enable-netcdf-4 --enable-parallel4 --disable-dap --disable-byterange --disable-nczarr \
    --disable-libxml2 --disable-testsets --disable-utilities
make -j"$(nproc)"
make install-strip
[ "$("$WISE_PREFIX/bin/nc-config" --has-parallel4)" = yes ] || wise_fail "NetCDF-4 parallel I/O is off"
wise_done
