#!/bin/sh
set -eu
wise_id=hdf5
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_apt zlib1g-dev
wise_workdir
cd "$WISE_WORK"
version=2.2.0
wise_fetch_tar "https://github.com/HDFGroup/hdf5/releases/download/$version/hdf5-$version.tar.gz" \
    1a1ab8209b35586fbc1aa279ba76d102130b95badcb20ca329587219112d8c16 src
if wise_cuda; then wise_nvfortran_env; fi
# Extraction strips the leading dot and leaves the versioned directory.
cmake -S "src/hdf5-$version" -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_CPP_LIB=OFF \
    -DHDF5_BUILD_JAVA=OFF -DHDF5_ENABLE_PARALLEL=ON -DHDF5_BUILD_FORTRAN=ON -DHDF5_ENABLE_ZLIB_SUPPORT=ON \
    -DCMAKE_C_COMPILER="$WISE_MPI_ROOT/bin/mpicc" -DCMAKE_Fortran_COMPILER="$WISE_MPI_ROOT/bin/mpifort"
cmake --build build -j"$(nproc)"
cmake --install build --strip
grep -q 'define H5_HAVE_PARALLEL 1' "$WISE_PREFIX/include/H5pubconf.h" || wise_fail "HDF5 was built without MPI-IO"
wise_done
