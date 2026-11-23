#!/bin/sh
set -eu
wise_id=hdf5
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_apt zlib1g-dev
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://github.com/HDFGroup/hdf5/releases/download/2.2.0/hdf5-2.2.0.tar.gz \
    1a1ab8209b35586fbc1aa279ba76d102130b95badcb20ca329587219112d8c16 src
build() { # prefix builddir
    cmake -S src -B "$2" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$1" -DBUILD_SHARED_LIBS=ON \
        -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_CPP_LIB=OFF \
        -DHDF5_BUILD_JAVA=OFF -DHDF5_ENABLE_PARALLEL=ON -DHDF5_BUILD_FORTRAN=ON -DHDF5_ENABLE_ZLIB_SUPPORT=ON \
        -DCMAKE_C_COMPILER="$WISE_PREFIX/bin/mpicc" -DCMAKE_Fortran_COMPILER="$WISE_PREFIX/bin/mpifort"
    cmake --build "$2" -j"$(nproc)"
    cmake --install "$2" --strip
}
build "$WISE_PREFIX" build
if wise_cuda; then
    # Fortran modules are compiler specific: nvfortran programs get their own copy.
    (wise_nvfortran_env && build "$WISE_NVHPC_PREFIX" build-nvhpc)
    echo "$WISE_NVHPC_PREFIX/lib" > /etc/ld.so.conf.d/wise-nvhpc.conf
fi
grep -q 'define H5_HAVE_PARALLEL 1' "$WISE_PREFIX/include/H5pubconf.h" || wise_fail "HDF5 was built without MPI-IO"
wise_done
