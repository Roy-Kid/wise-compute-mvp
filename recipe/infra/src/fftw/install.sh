#!/bin/sh
set -eu
wise_id=fftw
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://www.fftw.org/fftw-3.3.11.tar.gz \
    5630c24cdeb33b131612f7eb4b1a9934234754f9f388ff8617458d0be6f239a1 src
# SIMD kernels are chosen at run time, so the build stays portable across x86-64 CPUs. Double precision
# (libfftw3*) and single precision (libfftw3f*) come from the same source.
for precision in double single; do
    set -- --prefix="$WISE_PREFIX" --enable-shared --disable-static CC=gcc \
        --enable-openmp --enable-threads --enable-sse2 --enable-avx --enable-avx2 \
        --enable-avx512 --enable-fma
    ! wise_mpi || set -- "$@" --enable-mpi MPICC="$WISE_MPI_ROOT/bin/mpicc"
    [ "$precision" = double ] || set -- "$@" --enable-float
    mkdir "$precision"
    (cd "$precision" && ../src/configure "$@" && make -j"$(wise_build_jobs)" && make install-strip)
done
for lib in libfftw3 libfftw3_omp libfftw3_threads libfftw3f libfftw3f_omp libfftw3f_threads \
    $(! wise_mpi || echo libfftw3_mpi libfftw3f_mpi); do
    test -e "$WISE_PREFIX/lib/$lib.so" || wise_fail "$lib was not built"
done
wise_done
