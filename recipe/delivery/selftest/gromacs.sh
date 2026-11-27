#!/bin/sh
set -eu
# 64 argon-like atoms on a cubic lattice in a 3 nm box, half with a small positive and half with a small negative
# charge so that PME has work to do. The topology is written here: no force field files are needed.
awk 'BEGIN {
    print "charged argon"; print 64
    for (i = 0; i < 4; i++) for (j = 0; j < 4; j++) for (k = 0; k < 4; k++) {
        name = ++n <= 32 ? "ARP" : "ARM"
        printf "%5d%-5s%5s%5d%8.3f%8.3f%8.3f\n", n, name, "AR", n, 0.375 + 0.75 * i, 0.375 + 0.75 * j, 0.375 + 0.75 * k
    }
    print "   3.00000   3.00000   3.00000"
}' > argon.gro
cat > topol.top <<'TOP'
[ defaults ]
1 2 no 1.0 1.0
[ atomtypes ]
AR 39.948 0.0 A 0.3405 0.996
[ moleculetype ]
ARP 0
[ atoms ]
1 AR 1 ARP AR 1 0.1 39.948
[ moleculetype ]
ARM 0
[ atoms ]
1 AR 1 ARM AR 1 -0.1 39.948
[ system ]
charged argon
[ molecules ]
ARP 32
ARM 32
TOP
cat > md.mdp <<'MDP'
integrator = md
dt = 0.002
nsteps = 200
cutoff-scheme = Verlet
coulombtype = PME
rcoulomb = 1.0
rvdw = 1.0
tcoupl = no
pcoupl = no
gen_vel = yes
gen_temp = 80
gen_seed = 2026
nstenergy = 100
nstlog = 100
MDP
export GMX_MAXBACKUP=-1
gmx grompp -f md.mdp -c argon.gro -p topol.top -o md.tpr > grompp.out 2>&1 || { cat grompp.out; exit 1; }
finished() { # name: the run ended normally and the atoms kept a sensible temperature
    grep -q 'Finished mdrun' "$1.log" || { cat "$1.out"; echo "GROMACS did not finish the $1 run" >&2; exit 1; }
    echo Temperature | gmx energy -f "$1.edr" -o "$1.xvg" > "$1-energy.out" 2>&1 || { cat "$1-energy.out"; exit 1; }
    awk '$1 !~ /^[#@]/ { value = $2; found = 1 } END { if (!found || !(value > 1 && value < 1000)) exit 1 }' "$1.xvg" \
        || { cat "$1.xvg"; echo "GROMACS reports no sensible temperature for the $1 run" >&2; exit 1; }
}
# mdrun takes its OpenMP thread count from OMP_NUM_THREADS and refuses a different -ntomp.
OMP_NUM_THREADS=2 gmx mdrun -deffnm threads -s md.tpr -ntmpi 1 -nb cpu > threads.out 2>&1 || { cat threads.out; exit 1; }
finished threads
if command -v gmx_mpi > /dev/null && command -v mpirun > /dev/null; then
    OMP_NUM_THREADS=1 mpirun -n 2 gmx_mpi mdrun -deffnm ranks -s md.tpr -nb cpu > ranks.out 2>&1 || { cat ranks.out; exit 1; }
    grep -q 'Using 2 MPI processes' ranks.log || { cat ranks.log; echo 'gmx_mpi did not run on two ranks' >&2; exit 1; }
    finished ranks
fi
if [ "${SELFTEST_GPU:-0}" = 1 ] && gmx --version 2> /dev/null | grep -q '^GPU support: *CUDA'; then
    # On the device: mdrun refuses -nb gpu without a usable GPU, and its log names the one it selected.
    OMP_NUM_THREADS=2 gmx mdrun -deffnm gpu -s md.tpr -ntmpi 1 -nb gpu > gpu.out 2>&1 || { cat gpu.out; exit 1; }
    grep -Eq 'GPUs? selected for this run' gpu.log || { cat gpu.log; echo 'GROMACS did not run on the GPU' >&2; exit 1; }
    finished gpu
    printf '%s\n' 'GROMACS ran the non-bonded forces on the GPU'
fi
printf '%s\n' 'GROMACS ran 200 steps of molecular dynamics with PME on 64 atoms'
