#!/bin/sh
set -eu

: "${WISE_VENV:?install the python Feature before mpi4py}"
command -v mpicc >/dev/null || { echo "mpi4py: install an MPI Feature first" >&2; exit 1; }
# Build from source so the module links against the image's MPI rather than a bundled one.
"$WISE_VENV/bin/pip" install --no-cache-dir --no-binary mpi4py "mpi4py==${VERSION}"
