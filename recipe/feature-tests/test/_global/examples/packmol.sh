#!/bin/sh
set -eu
cat > water.xyz <<'XYZ'
3
water
O 0.000 0.000 0.000
H 0.957 0.000 0.000
H -0.240 0.927 0.000
XYZ
cat > pack.in <<'INPUT'
seed 4242
tolerance 2.0
filetype xyz
output packed.xyz
structure water.xyz
  number 5
  inside box 0. 0. 0. 15. 15. 15.
end structure
INPUT
packmol < pack.in > pack.out || { cat pack.out; exit 1; }
awk '
    NR == 1 { if ($1 != 15) exit 1 }
    NR >= 3 {
        ++atoms
        if ($1 != (atoms % 3 == 1 ? "O" : "H")) exit 1
        for (i = 2; i <= 4; i++) if ($i < -0.01 || $i > 15.01) exit 1
        for (i = 1; i <= atoms - (atoms - 1) % 3 - 1; i++) {
            dx = x[i] - $2; dy = y[i] - $3; dz = z[i] - $4
            if (dx*dx + dy*dy + dz*dz < 1.99*1.99) exit 1
        }
        x[atoms] = $2; y[atoms] = $3; z[atoms] = $4
    }
    END { if (atoms != 15) exit 1 }
' packed.xyz
printf '%s\n' 'Packmol packed five water molecules with the requested separation'
