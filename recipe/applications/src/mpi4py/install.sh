#!/bin/sh
set -eu
wise_id=mpi4py
. /opt/wise/lib/wise/feature.sh

wise_require python
wise_require_capability mpi
requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
mpi4py==4.1.2 --hash=sha256:56860286dc45f20e8821e93cb06669e30462348bf866f685553fa4b712d58d02
REQ
MPICC="$WISE_MPI_ROOT/bin/mpicc" "${WISE_VENV:?}/bin/pip" install --no-cache-dir --require-hashes --no-binary mpi4py -r "$requirements"
module=$(MPI4PY_RC_INITIALIZE=0 "$WISE_VENV/bin/python" -c 'import mpi4py.MPI as m; print(m.__file__)')
wise_mpi_linked "$module"
wise_done
