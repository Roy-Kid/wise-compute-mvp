#!/bin/sh
set -eu
cat > pair.in <<'LAMMPS'
units lj
atom_style atomic
region box block 0 8 0 8 0 8
create_box 1 box
create_atoms 1 single 3 4 4 units box
create_atoms 1 single 4.5 4 4 units box
mass 1 1.0
pair_style lj/cut 2.5
pair_coeff 1 1 1.0 1.0
thermo_modify norm no
run 0
print "$(pe:%.12f)" file energy-${ranks}.txt
LAMMPS
for ranks in 1 2; do
    mpirun -n "$ranks" lmp -var ranks "$ranks" -in pair.in -log none > "lammps-$ranks.out" || { cat "lammps-$ranks.out"; exit 1; }
done
awk 'function abs(x) { return x < 0 ? -x : x }
    { if (abs($1 - 4 * (1.5^(-12) - 1.5^(-6))) > 0.000001) exit 1 }
    END { if (NR != 2) exit 1 }
' energy-1.txt energy-2.txt
printf '%s\n' 'LAMMPS Lennard-Jones energy matches the analytic value on one and two MPI ranks'
