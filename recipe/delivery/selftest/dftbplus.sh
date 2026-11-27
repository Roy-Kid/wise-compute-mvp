#!/bin/sh
set -eu
cat > water.xyz <<'XYZ'
3
water
O 0.000000 0.000000 0.119262
H 0.000000 0.763239 -0.477047
H 0.000000 -0.763239 -0.477047
XYZ
# The xTB Hamiltonian needs no Slater-Koster files.
cat > dftb_in.hsd <<'HSD'
Geometry = xyzFormat {
  <<< "water.xyz"
}
Hamiltonian = xTB {
  Method = "GFN2-xTB"
}
HSD
OMP_NUM_THREADS=2 dftb+ > dftb.out 2>&1 || { cat dftb.out; exit 1; }
# The GFN2-xTB total energy of water is about -5.07 hartree.
awk '/^Total energy:/ { energy = $3 } END { if (energy == "" || energy <= -5.2 || energy >= -4.9) exit 1 }' detailed.out \
    || { cat dftb.out; exit 1; }
printf '%s\n' 'DFTB+ computed the GFN2-xTB energy of water'
