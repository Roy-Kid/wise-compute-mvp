#!/bin/sh
# Acceptance check for a delivered image. Run inside the image: verify.sh cpu|cuda
set -eu

variant=${1:?usage: verify.sh cpu|cuda}
case "$variant" in cpu|cuda) ;; *) echo "unknown variant: $variant" >&2; exit 2 ;; esac
: "${WISE_VENV:?WISE_VENV is missing; the python Feature is not installed}"

for tool in lmp pw.x wannier90.x packmol mpirun conda uv rustc cargo node npm; do
    command -v "$tool"
done
if command -v cp2k >/dev/null; then cp2k --version; else cp2k.psmp --version; fi
"$WISE_VENV/bin/python" -c 'import numpy; assert numpy.dot([2], [3]) == 6'
if [ "$(id -u)" -eq 0 ]; then
    export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
fi
mpirun -n 2 "$WISE_VENV/bin/python" -c \
    'from mpi4py import MPI; assert MPI.COMM_WORLD.allreduce(1) == 2'
if [ "$variant" = cpu ]; then
    test ! -d /usr/local/cuda
    exit
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
cat > in.cuda <<'LAMMPS'
units lj
atom_style atomic
lattice fcc 0.8442
region box block 0 3 0 3 0 3
create_box 1 box
create_atoms 1 box
mass 1 1.0
velocity all create 1.44 87287 loop geom
pair_style lj/cut/gpu 2.5
pair_coeff 1 1 1.0 1.0 2.5
fix integrate all nve
run 20
LAMMPS
# Explicit GPU pair style makes device initialization part of the test.
lmp-cuda -pk gpu 1 -in in.cuda
