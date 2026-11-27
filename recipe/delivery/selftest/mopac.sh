#!/bin/sh
set -eu
cat > water.mop <<'MOP'
PM7 1SCF
water

O 0.000000 1 0.000000 1 0.119262 1
H 0.000000 1 0.763239 1 -0.477047 1
H 0.000000 1 -0.763239 1 -0.477047 1
MOP
OMP_NUM_THREADS=2 mopac water.mop > mopac.log 2>&1 || { cat mopac.log water.out 2> /dev/null; exit 1; }
grep -q 'JOB ENDED NORMALLY' water.out || { cat water.out; exit 1; }
# PM7 gives water a heat of formation of about -58 kcal/mol.
awk '/FINAL HEAT OF FORMATION/ { for (i = 1; i <= NF; i++) if ($i == "=") { value = $(i + 1); break } }
    END { if (value == "" || value <= -65 || value >= -50) exit 1 }' water.out || { cat water.out; exit 1; }
printf '%s\n' 'MOPAC computed the PM7 heat of formation of water'
