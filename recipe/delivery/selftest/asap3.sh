#!/bin/sh
set -eu
cat > copper.py <<'PY'
from ase.build import bulk
from ase.calculators.emt import EMT as ReferenceEMT
from asap3 import EMT

atoms = bulk('Cu', 'fcc', a=3.61) * (4, 4, 4)
atoms.rattle(0.05, seed=1)
atoms.calc = EMT()
energy = atoms.get_potential_energy() / len(atoms)
# Asap and ASE implement the same effective medium theory, with slightly different cutoffs.
atoms.calc = ReferenceEMT()
reference = atoms.get_potential_energy() / len(atoms)
assert abs(energy - reference) < 0.02, (energy, reference)
PY
# An Asap built with MPI starts under its launcher.
launch() { if command -v mpirun > /dev/null; then mpirun -n 1 "$@"; else "$@"; fi; }
OMP_NUM_THREADS=1 launch python3 copper.py
printf '%s\n' 'Asap reproduced the effective medium theory energy of copper'
