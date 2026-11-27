#!/bin/sh
set -eu
cat > h2.py <<'PY'
import sys
from ase.build import molecule
from gpaw.mpi import world

ranks, device = int(sys.argv[1]), sys.argv[2]
assert world.size == ranks, f'{world.size} MPI ranks, expected {ranks}'
atoms = molecule('H2', vacuum=2.5)
atoms.pbc = True
if device == 'gpu':
    # The GPU code path of GPAW: it refuses to start without CuPy, and CuPy must see a device.
    import cupy
    from gpaw.gpu import cupy_is_fake
    from gpaw.new.ase_interface import GPAW
    assert not cupy_is_fake and cupy.cuda.runtime.getDeviceCount() > 0
    atoms.calc = GPAW(mode={'name': 'pw', 'ecut': 250}, xc='PBE', parallel={'gpu': True}, txt=f'h2-{device}.txt')
else:
    from gpaw import GPAW, PW
    atoms.calc = GPAW(mode=PW(250), xc='PBE', txt=f'h2-{ranks}.txt')
energy = atoms.get_potential_energy()
# GPAW counts from the isolated atoms: the PBE atomization energy of H2 is about 6.7 eV.
assert -7.5 < energy < -5.5, energy
if world.rank == 0:
    # Into a file: an MPI library may print notices of its own.
    with open(f'energy-{device}-{ranks}.txt', 'w') as file:
        print(f'{energy:.6f}', file=file)
PY
export OMP_NUM_THREADS=1
# A GPAW built with MPI starts under its launcher, also for one rank.
if command -v mpirun > /dev/null && python3 -c 'import _gpaw, sys; sys.exit(not hasattr(_gpaw, "Communicator"))'; then
    launch() { ranks=$1; shift; mpirun -n "$ranks" "$@"; }
    launch 2 python3 h2.py 2 cpu > h2-2.out 2>&1 || { cat h2-2.out; exit 1; }
    test -s energy-cpu-2.txt || { cat h2-2.txt 2> /dev/null; exit 1; }
else
    launch() { shift; "$@"; }
fi
launch 1 python3 h2.py 1 cpu > h2-1.out 2>&1 || { cat h2-1.out; exit 1; }
test -s energy-cpu-1.txt || { cat h2-1.txt 2> /dev/null; exit 1; }
if [ -e energy-cpu-2.txt ]; then
    awk 'function abs(x) { return x < 0 ? -x : x } NR == FNR { one = $1; next } { if (abs($1 - one) > 0.001) exit 1 }' energy-cpu-1.txt energy-cpu-2.txt
fi
if [ "${SELFTEST_GPU:-0}" = 1 ] && python3 -c 'import _gpaw, sys; sys.exit(not _gpaw.GPU_ENABLED)'; then
    launch 1 python3 h2.py 1 gpu > h2-gpu.out 2>&1 || { cat h2-gpu.out h2-gpu.txt 2> /dev/null; echo 'GPAW did not run on the GPU' >&2; exit 1; }
    printf '%s\n' 'GPAW ran its plane-wave mode on the GPU'
fi
printf '%s\n' 'GPAW converged the H2 energy in plane-wave mode'
