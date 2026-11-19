#!/bin/sh
set -eu

/opt/wise/venv/bin/python -c 'from mpi4py import MPI; assert MPI.COMM_WORLD.Get_size() == 1'
