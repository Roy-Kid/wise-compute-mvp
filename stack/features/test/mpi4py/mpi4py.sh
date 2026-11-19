#!/bin/sh
set -eu

"$WISE_VENV/bin/python" -c 'from mpi4py import MPI; assert MPI.COMM_WORLD.Get_size() == 1'
