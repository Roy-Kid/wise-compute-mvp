#!/bin/sh
set -eu
# Hirshfeld charges of acetic acid from a bundled wavefunction: 32 electrons, a neutral molecule, negative oxygens.
printf '7\n1\n1\nn\n0\nq\n' | Multiwfn "${MULTIWFN_EXAMPLES:-/usr/local/share/multiwfn/examples}/acetic_acid.wfn" > multiwfn.out \
    || { cat multiwfn.out; exit 1; }
grep -q 'Total/Alpha/Beta electrons: *32[.]0000' multiwfn.out
awk '
    /^ Hirshfeld charge of atom/ { ++atoms; sum += $NF; if ($0 ~ /\(O \)/ && $NF >= 0) exit 1 }
    END { if (atoms != 8 || sum > 1e-4 || sum < -1e-4) exit 1 }
' multiwfn.out || { cat multiwfn.out; exit 1; }
printf '%s\n' 'Multiwfn computed the Hirshfeld charges of acetic acid'
