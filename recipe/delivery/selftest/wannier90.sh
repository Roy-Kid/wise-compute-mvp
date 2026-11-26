#!/bin/sh
set -eu
cat > band.win <<'WIN'
num_bands = 1
num_wann = 1
num_iter = 0
write_hr = true
mp_grid = 1 1 1
begin unit_cell_cart
angstrom
5 0 0
0 5 0
0 0 5
end unit_cell_cart
begin atoms_frac
H 0 0 0
end atoms_frac
begin projections
H:s
end projections
begin kpoints
0 0 0
end kpoints
WIN
wannier90.x -pp band
# One orthonormal orbital, constant overlap and a flat 1.25 eV band.
awk '
    /begin nnkpts/ { getline; print "flat band overlaps"; print 1, 1, $1; active=1; next }
    /end nnkpts/ { active=0 }
    active { print; print "1.0 0.0" }
' band.nnkp > band.mmn
printf 'flat band projections\n1 1 1\n1 1 1 1.0 0.0\n' > band.amn
printf '1 1 1.25\n' > band.eig
wannier90.x band
test -s band_hr.dat
awk '
    NF == 7 && $1 == 0 && $2 == 0 && $3 == 0 && $4 == 1 && $5 == 1 {
        if ($6 < 1.24999 || $6 > 1.25001 || $7 < -0.00001 || $7 > 0.00001) exit 1
        found=1
    }
    END { if (!found) exit 1 }
' band_hr.dat
printf '%s\n' 'Wannier90 recovered the 1.25 eV on-site Hamiltonian element'
