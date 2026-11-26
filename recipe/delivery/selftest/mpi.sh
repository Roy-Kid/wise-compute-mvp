#!/bin/sh
set -eu
cat > sum.c <<'C'
#include <mpi.h>
int main(int argc, char **argv) {
    int size, rank, total, provided;
    if (MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided) != MPI_SUCCESS) return 1;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    MPI_Allreduce(&rank, &total, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD);
    MPI_Finalize();
    return size != 2 || total != 1 || provided < MPI_THREAD_SERIALIZED;
}
C
mpicc sum.c -o sum
mpirun -n 2 ./sum
printf '%s\n' 'MPI two-rank all-reduce passed'
