# syntax=docker/dockerfile:1
# Base tier, CUDA: the NVIDIA HPC SDK image (nvhpc 25.7, CUDA 12.9, Ubuntu 24.04). Everything NVIDIA is
# provided and adjusted here and nowhere else; upper tiers see it only through NVHPC_ROOT, CUDA_HOME and
# GDRCOPY_HOME (GPUDirect copies for UCX and libfabric).
ARG BASE_IMAGE=nvcr.io/nvidia/nvhpc@sha256:777412a2977d4feeb054d1076d6cfb74dd4afbb44c2b0225c70554bc298b9dbc
FROM ${BASE_IMAGE}

ENV NVHPC_ROOT=/opt/nvidia/hpc_sdk/Linux_x86_64/25.7
ENV CUDA_HOME=${NVHPC_ROOT}/cuda
ENV GDRCOPY_HOME=/usr/local/gdrcopy

ARG APT_SNAPSHOT=20261101T000000Z
RUN . /etc/os-release && test "$VERSION_ID" = 24.04 \
    # Keep every apt source under the Ubuntu snapshot; the SDK is already in the image.
    && rm -f /etc/apt/sources.list.d/*cuda* /etc/apt/sources.list.d/*nvidia* \
    && printf 'APT::Snapshot "%s";\n' "$APT_SNAPSHOT" > /etc/apt/apt.conf.d/50wise-snapshot \
    # One MPI per image: the infra tier builds it (CUDA-aware here). Remove the SDK's HPC-X / Open MPI.
    && find "$NVHPC_ROOT/comm_libs" -maxdepth 2 \( -name mpi -o -name 'hpcx*' -o -name 'openmpi*' \) \
        -exec rm -rf {} + \
    && ! command -v mpirun \
    # GDRCopy user library (GPUDirect RDMA copies for UCX and libfabric), one pinned commit, no history.
    # The gdrdrv kernel module belongs to the host; without it the library falls back to cudaMemcpy.
    && apt-get update && apt-get install -y --no-install-recommends git ca-certificates make \
    && rm -rf /var/lib/apt/lists/* \
    && src=$(mktemp -d) && git init --quiet "$src" \
    && git -C "$src" fetch --quiet --depth 1 --no-tags https://github.com/NVIDIA/gdrcopy.git \
        7344efbd4e0a2ba9da2183b4cc0f10a092b3ca67 \
    && git -C "$src" checkout --quiet FETCH_HEAD \
    && make -C "$src" prefix="$GDRCOPY_HOME" CUDA="$CUDA_HOME" CC=gcc lib lib_install \
    && rm -rf "$src" && echo "$GDRCOPY_HOME/lib" > /etc/ld.so.conf.d/gdrcopy.conf && ldconfig \
    # The contract the GPU builds in the applications tier rely on.
    && for tool in nvc nvc++ nvfortran nvcc; do command -v "$tool"; done \
    && for path in "$CUDA_HOME/include/cuda_runtime.h" "$CUDA_HOME/lib64/libcudart.so" \
        "$CUDA_HOME/lib64/stubs/libcuda.so" "$NVHPC_ROOT/math_libs/include/cufft.h" \
        "$NVHPC_ROOT/math_libs/lib64/libcufft.so" "$NVHPC_ROOT/math_libs/lib64/libcublas.so" \
        "$NVHPC_ROOT/math_libs/lib64/libcusolver.so" "$GDRCOPY_HOME/include/gdrapi.h"; do test -e "$path"; done \
    && ls "$GDRCOPY_HOME"/lib*/libgdrapi.so*
