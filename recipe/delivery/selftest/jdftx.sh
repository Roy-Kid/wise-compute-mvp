#!/bin/sh
set -eu
# H2 in a 12 bohr box with the GBRV pseudopotentials that JDFTx installs. The bond is shorter than two core
# radii of this ultrasoft potential, which JDFTx refuses unless told that it is intended.
cat > h2.in <<'JDFTX'
lattice Cubic 12
coords-type Cartesian
ion-species GBRV/$ID_pbe.uspp
elec-cutoff 20 100
elec-ex-corr gga-PBE
core-overlap-check none
ion H 5.3 6 6 0
ion H 6.7 6 6 0
dump End None
JDFTX
export OMP_NUM_THREADS=2
# A program built with MPI starts under its launcher; a threaded build has none.
launch() { if command -v mpirun > /dev/null; then mpirun -n 2 "$@"; else "$@"; fi; }
scf() { # program name
    launch "$1" -c 1 -i h2.in -o "$2.out" > "$2.log" 2>&1 || { cat "$2.log" "$2.out" 2> /dev/null; exit 1; }
    grep -q '^Done!' "$2.out" || { tail -n 60 "$2.out"; echo "$1 did not finish" >&2; exit 1; }
    # The total energy of H2 is about -1.17 hartree.
    awk '/^ElecMinimize: Iter:/ { for (i = 1; i < NF; i++) if ($i == "Etot:") energy = $(i + 1) }
        END { if (energy == "" || energy <= -1.25 || energy >= -1.05) exit 1 }' "$2.out"
}
scf jdftx cpu
if [ "${SELFTEST_GPU:-0}" = 1 ] && command -v jdftx_gpu > /dev/null; then
    scf jdftx_gpu gpu
    grep -q '^gpuInit: Selected device' gpu.out || { cat gpu.out; echo 'JDFTx did not run on the GPU' >&2; exit 1; }
    printf '%s\n' 'JDFTx ran on the GPU'
fi
printf '%s\n' 'JDFTx converged the H2 energy with its GBRV pseudopotentials'
