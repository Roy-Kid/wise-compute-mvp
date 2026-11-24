# syntax=docker/dockerfile:1
# NVIDIA HPC SDK 25.7 with CUDA 12.9 on Ubuntu 24.04.
ARG BASE_IMAGE=nvcr.io/nvidia/nvhpc@sha256:777412a2977d4feeb054d1076d6cfb74dd4afbb44c2b0225c70554bc298b9dbc
FROM ${BASE_IMAGE}

ENV NVHPC_ROOT=/opt/nvidia/hpc_sdk/Linux_x86_64/25.7
# The versioned directory: cuda/bin is a link into it, so CMake would resolve nvcc's "bin/.." to a cuda/
# without targets/.
ENV CUDA_HOME=${NVHPC_ROOT}/cuda/12.9
ENV GDRCOPY_HOME=/usr/local/gdrcopy
ENV HPCX_HOME=${NVHPC_ROOT}/comm_libs/12.9/hpcx/latest
ENV WISE_BASE_MPI=openmpi
ENV WISE_MPI_ROOT=${HPCX_HOME}/ompi
ENV OPAL_PREFIX=${WISE_MPI_ROOT}
ENV PATH=${WISE_MPI_ROOT}/bin:${HPCX_HOME}/ucx/bin:${CUDA_HOME}/bin:${PATH}
ENV OMPI_CC=gcc OMPI_CXX=g++ OMPI_FC=nvfortran

ARG APT_SNAPSHOT=20261101T000000Z
RUN set -eu; \
    . /etc/os-release; test "$VERSION_ID" = 24.04; \
    rm -f /etc/apt/sources.list.d/*cuda* /etc/apt/sources.list.d/*nvidia*; \
    printf 'APT::Snapshot "%s";\n' "$APT_SNAPSHOT" > /etc/apt/apt.conf.d/50wise-snapshot

# Use the CUDA 12.9 HPC-X libraries for both builds and runs, including builders without a GPU.
RUN bash -ec '. "$HPCX_HOME/hpcx-init.sh"; hpcx_load; \
    printf "%s\n" "$LD_LIBRARY_PATH" | tr ":" "\n" | sed "/^$/d" > /etc/ld.so.conf.d/00-wise-hpcx.conf; \
    ldconfig; \
    for tool in mpicc mpicxx mpifort mpirun ompi_info; do test -x "$WISE_MPI_ROOT/bin/$tool"; done; \
    test -e "$WISE_MPI_ROOT/lib/libmpi.so"'

# GDRCopy supplies the userspace library for UCX and libfabric.
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends git ca-certificates make; \
    rm -rf /var/lib/apt/lists/*; \
    src=$(mktemp -d); \
    git init --quiet "$src"; \
    git -C "$src" fetch --quiet --depth 1 --no-tags https://github.com/NVIDIA/gdrcopy.git \
        7344efbd4e0a2ba9da2183b4cc0f10a092b3ca67; \
    git -C "$src" checkout --quiet FETCH_HEAD; \
    make -C "$src" prefix="$GDRCOPY_HOME" CUDA="$CUDA_HOME" CC=gcc lib lib_install; \
    rm -rf "$src"; \
    echo "$GDRCOPY_HOME/lib" > /etc/ld.so.conf.d/gdrcopy.conf; \
    ldconfig; \
    for tool in nvc nvc++ nvfortran nvcc; do command -v "$tool"; done; \
    test "$(command -v nvcc)" = "$CUDA_HOME/bin/nvcc"; \
    for path in "$CUDA_HOME/targets/x86_64-linux/include" "$CUDA_HOME/include/cuda_runtime.h" "$CUDA_HOME/lib64/libcudart.so" \
        "$CUDA_HOME/lib64/stubs/libcuda.so" "$NVHPC_ROOT/math_libs/include/cufft.h" \
        "$NVHPC_ROOT/math_libs/lib64/libcufft.so" "$NVHPC_ROOT/math_libs/lib64/libcublas.so" \
        "$NVHPC_ROOT/math_libs/lib64/libcusolver.so" "$GDRCOPY_HOME/include/gdrapi.h"; do test -e "$path"; done; \
    ls "$GDRCOPY_HOME"/lib*/libgdrapi.so*
