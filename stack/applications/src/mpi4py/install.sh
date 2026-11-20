#!/bin/sh
set -eu

feature=mpi4py
: "${WISE_VENV:?WISE_VENV must be set by the python Feature}"
[ -x /opt/wise/bin/mpicc ] || { echo "$feature: the delivery must select an MPI Feature (openmpi or mpich)" >&2; exit 1; }
linked() { # binary pattern...
    libs=$(ldd "$1")
    if echo "$libs" | grep -q "not found"; then echo "$libs" >&2; exit 1; fi
    bin=$1; shift
    for pattern; do
        echo "$libs" | grep -q "$pattern" || { echo "$feature: $bin does not link $pattern" >&2; exit 1; }
    done
}
requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
mpi4py==4.1.2 --hash=sha256:56860286dc45f20e8821e93cb06669e30462348bf866f685553fa4b712d58d02
REQ
MPICC=/opt/wise/bin/mpicc "$WISE_VENV/bin/pip" install --no-cache-dir --require-hashes --no-binary mpi4py -r "$requirements"
linked "$("$WISE_VENV/bin/python" -c 'import mpi4py.MPI as m; print(m.__file__)')" /opt/wise/lib/libmpi
