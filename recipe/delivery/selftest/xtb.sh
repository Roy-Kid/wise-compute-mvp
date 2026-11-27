#!/bin/sh
set -eu
cat > water.xyz <<'XYZ'
3
water
O 0.000000 0.000000 0.119262
H 0.000000 0.763239 -0.477047
H 0.000000 -0.763239 -0.477047
XYZ
export OMP_NUM_THREADS=2
xtb water.xyz --gfn 2 --sp > xtb.out 2>&1 || { cat xtb.out; exit 1; }
grep -q 'normal termination of xtb' xtb.out || { cat xtb.out; exit 1; }
# The GFN2-xTB total energy of water is about -5.07 hartree.
awk '/TOTAL ENERGY/ { energy = $4 } END { if (energy == "" || energy <= -5.2 || energy >= -4.9) exit 1; print energy }' xtb.out > energy.txt \
    || { cat xtb.out; exit 1; }
if python3 -c 'import tblite.ase, ase' 2> /dev/null; then
    # The ASE calculator of tblite must give the same energy as the program.
    cat > water.py <<'PY'
import sys
from ase.io import read
from ase.units import Hartree
from tblite.ase import TBLite

atoms = read('water.xyz')
atoms.calc = TBLite(method='GFN2-xTB', verbosity=0)
energy = atoms.get_potential_energy() / Hartree
assert abs(energy - float(sys.argv[1])) < 1e-4, (energy, sys.argv[1])
PY
    python3 water.py "$(cat energy.txt)"
    printf '%s\n' 'The tblite ASE calculator reproduces the xtb energy'
fi
printf '%s\n' 'xtb computed the GFN2-xTB energy of water'
