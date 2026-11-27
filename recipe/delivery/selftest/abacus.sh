#!/bin/sh
set -eu
# Pseudopotential and numerical orbitals of the ABACUS test suite, which the image installs with the program.
data=/usr/local/share/abacus/PP_ORB
cat > STRU.pw <<'STRU'
ATOMIC_SPECIES
H 1.008 H_ONCV_PBE-1.0.upf

LATTICE_CONSTANT
1.8897259886

LATTICE_VECTORS
6 0 0
0 6 0
0 0 6

ATOMIC_POSITIONS
Cartesian

H
0.0
2
3.00 3.00 3.00 0 0 0
3.74 3.00 3.00 0 0 0
STRU
{ sed -n '1,3p' STRU.pw; printf 'NUMERICAL_ORBITAL\nH_gga_6au_60Ry_2s1p.orb\n\n'; sed -n '4,$p' STRU.pw; } > STRU.lcao
cat > KPT <<'KPT'
K_POINTS
0
Gamma
1 1 1 0 0 0
KPT
scf() { # name basis [input line...]: one SCF calculation of H2 in its own directory
    name=$1 basis=$2; shift 2
    mkdir "$name"
    cp KPT "$name/KPT"
    cp "STRU.$basis" "$name/STRU"
    {
        printf '%s\n' INPUT_PARAMETERS "suffix $name" 'calculation scf' "basis_type $basis" 'ecutwfc 60' 'scf_thr 1e-7' \
            "pseudo_dir $data" "orbital_dir $data"
        for line; do printf '%s\n' "$line"; done
    } > "$name/INPUT"
    (cd "$name" && OMP_NUM_THREADS=1 mpirun -n 2 abacus > abacus.out 2>&1) || { cat "$name/abacus.out"; exit 1; }
    log=$name/OUT.$name/running_scf.log
    grep -q 'charge density convergence is achieved' "$log" || { tail -n 60 "$log"; echo "ABACUS did not converge the $name run" >&2; exit 1; }
    # The total energy of H2 is about -31.7 eV.
    awk '/!FINAL_ETOT_IS/ { if ($2 <= -33 || $2 >= -30) exit 1; found = 1 } END { if (!found) exit 1 }' "$log"
}
scf pw pw
# Atomic orbitals: the Hamiltonian is diagonalized by ELPA.
scf lcao lcao 'ks_solver genelpa' 'gamma_only 1'
if [ "${SELFTEST_GPU:-0}" = 1 ] && ldd "$(command -v abacus)" | grep -q libcusolver; then
    scf gpu pw 'device gpu'
    grep -q 'RUNNING WITH DEVICE  : GPU' gpu/OUT.gpu/running_scf.log || { echo 'ABACUS did not run on the GPU' >&2; exit 1; }
    printf '%s\n' 'ABACUS ran the plane-wave SCF on the GPU'
fi
printf '%s\n' 'ABACUS converged the H2 SCF with plane waves and with atomic orbitals on two MPI ranks'
