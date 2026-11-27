#!/bin/sh
set -eu
# The KIM API installs a few example models; an OpenKIM model is used in the same way.
kim-api-collections-management list > models.txt 2>&1 || { cat models.txt; exit 1; }
grep -q 'ex_model_Ar_P_Morse_07C' models.txt || { cat models.txt; echo 'the example models are missing' >&2; exit 1; }
if python3 -c 'import kimpy, ase' 2> /dev/null; then
    cat > argon.py <<'PY'
from ase.build import bulk
from ase.calculators.kim import KIM

atoms = bulk('Ar', 'fcc', a=5.26) * (3, 3, 3)
atoms.calc = KIM('ex_model_Ar_P_Morse_07C')
energy = atoms.get_potential_energy() / len(atoms)
# A Morse model of solid argon binds each atom by a fraction of an eV.
assert -1.0 < energy < 0, energy
PY
    python3 argon.py
    printf '%s\n' 'The ASE KIM calculator computed the energy of solid argon with a KIM model'
fi
printf '%s\n' 'The KIM API lists its installed models'
