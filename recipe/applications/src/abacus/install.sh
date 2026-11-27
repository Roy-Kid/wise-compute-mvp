#!/bin/sh
set -eu
wise_id=abacus
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_require_capability mpi
variant=${VARIANT:-cpu}
arch=$(echo "${CUDAARCH:-80}" | tr -d ' ' | tr ',' ';')
case "$variant" in
    cpu) ;;
    cuda)
        wise_cuda || wise_fail "variant=cuda needs the CUDA base image"
        echo "$arch" | grep -Eqx '[1-9][0-9]*(;[1-9][0-9]*)*' || wise_fail "cudaArch is a list of compute capabilities such as 80,90"
        ;;
    *) wise_fail "unknown variant $variant" ;;
esac
# Cereal is the header-only serialization library of the atomic orbital code.
wise_apt libcereal-dev
wise_workdir
wise_fetch_git https://github.com/deepmodeling/abacus-develop.git f71921fe848659deac8db319cd4311b55b5ad480 "$WISE_WORK/src"

# ELPA is named by its files: its pkg-config flags are those of the compiler that built it.
elpa_include=$(pkg-config --variable=includedir elpa_openmp)/elpa_openmp-$(pkg-config --modversion elpa_openmp)
elpa_library=$(pkg-config --variable=libdir elpa_openmp)/libelpa_openmp.so
set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DCMAKE_CXX_COMPILER="$WISE_MPI_ROOT/bin/mpicxx" -DMPI_CXX_COMPILER="$WISE_MPI_ROOT/bin/mpicxx" \
    -DENABLE_MPI=ON -DUSE_OPENMP=ON -DENABLE_LCAO=ON -DENABLE_LIBXC=ON -DUSE_ELPA=ON \
    -DELPA_INCLUDE_DIR="$elpa_include" -DELPA_LIBRARIES="$elpa_library" -DSCALAPACK_DIR="$WISE_PREFIX" \
    -DBLA_VENDOR=OpenBLAS -DENABLE_NATIVE_OPTIMIZATION=OFF -DGIT_SUBMODULE=OFF -DBUILD_TESTING=OFF
if [ "$variant" = cuda ]; then
    # The HPC SDK keeps cuBLAS, cuSOLVER and cuFFT outside the CUDA directory. abacus needs the CUDA driver,
    # which the SDK supplies on GPU-less builders.
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$CUDA_HOME/compat"
    # ABACUS links the CUDA libraries by name, and looks up the toolkit version (which decides whether the
    # removed nvToolsExt is linked) only when it also chooses the architectures itself.
    export LIBRARY_PATH="${NVHPC_ROOT:?}/math_libs/lib64:$CUDA_HOME/lib64${LIBRARY_PATH:+:$LIBRARY_PATH}"
    cuda_version=$("$CUDA_HOME/bin/nvcc" --version | sed -n 's/.*release \([0-9.]*\),.*/\1/p')
    [ -n "$cuda_version" ] || wise_fail "nvcc does not report its version"
    set -- "$@" -DUSE_CUDA=ON -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" "-DCMAKE_CUDA_ARCHITECTURES=$arch" \
        -DCUDAToolkit_ROOT="$CUDA_HOME" -DCUDAToolkit_VERSION="$cuda_version" -DCMAKE_PREFIX_PATH="$NVHPC_ROOT/math_libs;$WISE_PREFIX"
else
    set -- "$@" -DUSE_CUDA=OFF -DCMAKE_PREFIX_PATH="$WISE_PREFIX"
fi
# cmakeArgs is a space separated list by contract; no globbing while it is split.
set -f
# shellcheck disable=SC2086
set -- "$@" ${CMAKEARGS:-}
set +f
cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" "$@"
# Whatever the options said (cmakeArgs included), check what will actually be built.
cache=$WISE_WORK/build/CMakeCache.txt
on() { grep -q "^$1:BOOL=ON$" "$cache"; }
on ENABLE_MPI && on ENABLE_LCAO && on USE_ELPA || wise_fail "ABACUS must be built with MPI, atomic orbitals and ELPA"
if [ "$variant" = cuda ]; then on USE_CUDA || wise_fail "variant=cuda needs USE_CUDA"
else ! on USE_CUDA || wise_fail "variant=cpu builds no CUDA kernels"; fi
! grep -q '^FETCHCONTENT_BASE_DIR' "$cache" || [ -z "$(ls "$WISE_WORK/build/_deps" 2>/dev/null)" ] \
    || wise_fail "ABACUS would download third-party code"
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build" --strip
# The source tree's own pseudopotentials and numerical orbitals, enough for its examples and quick tests.
mkdir -p "$WISE_PREFIX/share/abacus"
cp -R "$WISE_WORK/src/tests/PP_ORB" "$WISE_PREFIX/share/abacus/PP_ORB"
wise_mpi_linked "$WISE_PREFIX/bin/abacus" "$WISE_PREFIX/lib/libfftw3" "$WISE_PREFIX/lib/libscalapack" \
    "$WISE_PREFIX/lib/libelpa_openmp" "$WISE_PREFIX/lib/libxc" libopenblas libgomp
[ "$variant" != cuda ] || wise_linked "$WISE_PREFIX/bin/abacus" libcusolver libcublas libcufft
wise_done
