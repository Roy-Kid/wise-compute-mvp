#!/bin/sh
set -eu
cat > water.py <<'PY'
from ase.build import molecule
from dftd4.ase import DFTD4

atoms = molecule('H2O')
atoms.calc = DFTD4(method='PBE')
energy = atoms.get_potential_energy()
# The dispersion correction of one water molecule is a few meV, and attractive.
assert -0.05 < energy < 0, energy
PY
python3 water.py
printf '%s\n' 'DFT-D4 gave an attractive dispersion energy for water through its ASE calculator'
