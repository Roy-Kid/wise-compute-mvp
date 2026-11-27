#!/bin/sh
set -eu
cat > silicon.py <<'PY'
from ase.build import bulk
from atomistica import Tersoff

atoms = bulk('Si', 'diamond', a=5.432) * (2, 2, 2)
atoms.calc = Tersoff()
energy = atoms.get_potential_energy() / len(atoms)
# The Tersoff potential gives diamond silicon a cohesive energy of 4.63 eV per atom.
assert -4.70 < energy < -4.55, energy
PY
OMP_NUM_THREADS=1 python3 silicon.py
printf '%s\n' 'Atomistica reproduced the Tersoff cohesive energy of silicon'
