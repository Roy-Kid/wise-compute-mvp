#!/bin/sh
set -eu
# The driver reads the cell from the second line of an xyz file.
cat > trajectory.xyz <<'XYZ'
2
100.0 100.0 100.0
H 0.0 0.0 0.0
H 1.5 0.0 0.0
XYZ
cat > plumed.dat <<'PLUMED'
UNITS LENGTH=A
bond: DISTANCE ATOMS=1,2 NOPBC
PRINT ARG=bond FILE=distance.dat STRIDE=1
PLUMED
plumed driver --plumed plumed.dat --ixyz trajectory.xyz --length-units A > plumed.out || { cat plumed.out; exit 1; }
awk '$1 !~ /^#/ { if ($2 < 1.49999 || $2 > 1.50001) exit 1; found=1 } END { if (!found) exit 1 }' distance.dat
printf '%s\n' 'PLUMED measured the expected 1.5 Å separation'
