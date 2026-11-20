#!/bin/sh
# Acceptance for a delivered image, run inside it as an unprivileged user:
#   docker run --rm -i --user 65534:65534 --network none --tmpfs /tmp:mode=1777 \
#     --entrypoint /bin/sh IMAGE -s cpu|cuda < stack/delivery/verify.sh
# For cuda, run on a GPU node with --gpus 1 to exercise the GPU paths; WISE_VERIFY_GPU=0 skips them.
set -eu

variant=${1:?usage: verify.sh cpu|cuda}
case "$variant" in cpu|cuda) ;; *) echo "unknown variant: $variant" >&2; exit 2 ;; esac
: "${WISE_VENV:?WISE_VENV is missing; the python Feature is not installed}"

for tool in lmp pw.x ph.x pw2wannier90.x wannier90.x cp2k.psmp packmol mpirun conda uv rustc cargo node npm; do
    command -v "$tool"
done

# One MPI: every MPI binary resolves libmpi from /opt/wise, and nothing else provides mpirun.
for binary in /opt/wise/bin/lmp /opt/wise/bin/pw.x /opt/wise/bin/cp2k.psmp \
    "$("$WISE_VENV/bin/python" -c 'import mpi4py.MPI as m; print(m.__file__)')"; do
    ldd "$binary" | grep -q '/opt/wise/lib/libmpi' || { echo "$binary does not link /opt/wise/lib/libmpi" >&2; exit 1; }
    ! ldd "$binary" | grep -q 'not found' || { ldd "$binary" >&2; exit 1; }
done
test "$(command -v mpirun)" = /opt/wise/bin/mpirun

"$WISE_VENV/bin/python" -c 'import numpy; assert numpy.dot([2], [3]) == 6'
mpirun -n 2 "$WISE_VENV/bin/python" -c 'from mpi4py import MPI; assert MPI.COMM_WORLD.allreduce(1) == 2'
cp2k.psmp --version

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
cat > in.lj <<'LAMMPS'
units lj
atom_style atomic
lattice fcc 0.8442
region box block 0 6 0 6 0 6
create_box 1 box
create_atoms 1 box
mass 1 1.0
velocity all create 1.44 87287 loop geom
pair_style lj/cut 2.5
pair_coeff 1 1 1.0 1.0 2.5
fix integrate all nve
run 50
LAMMPS
mpirun -n 2 lmp -in in.lj -log none -screen none

if [ "$variant" = cpu ]; then
    test -z "${CUDA_HOME:-}" && ! command -v nvcc >/dev/null
    exit
fi
lmp -h | grep -q 'KOKKOS package API:.*CUDA'
ldd /opt/wise/bin/pw.x | grep -q libcufft
ldd /opt/wise/bin/cp2k.psmp | grep -q libcudart
[ "${WISE_VERIFY_GPU:-1}" = 1 ] || exit 0
nvidia-smi -L
# Run on the device: KOKKOS must initialize the GPU and finish the run.
lmp -k on g 1 -sf kk -in in.lj -log none -screen none
