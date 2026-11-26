#!/bin/sh

qe_cuda_architectures() {
    printf '%s\n' "$1" | awk -F, '
        {
            for (i = 1; i <= NF; i++) {
                if ($i !~ /^[0-9]+$/) exit 1
                architectures = architectures (i == 1 ? "" : ";") "sm_" $i
            }
            if (!NF) exit 1
            print architectures
        }'
}

qe_cuda_cmake() {
    qe_architectures=$1
    shift
    cmake '-DQE_GPU:STRING=openacc;cuda' "-DQE_GPU_ARCHS:STRING=$qe_architectures" \
        -DQE_ENABLE_MPI_GPU_AWARE=ON -DQE_ENABLE_OPENMP=OFF "$@"
}
