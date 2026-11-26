#!/bin/sh
set -eu
# An H PAW potential generated on the fly with QE's atomic code. https://github.com/QEF/q-e/tree/develop/atomic/examples/paw_examples
cat > atom.in <<'ATOM'
&input
 title='H', zed=1, config='1s1 2p0', iswitch=3, dft='PBE'
/
&inputp
 pseudotype=3, lloc=1, zval=1, lpaw=.true., tm=.true.,
 lnc2paw=.false., which_augfun='PSQ', rmatch_augfun=0.8,
 file_pseudopw='H.UPF'
/
3
1S 1 0 1.00 0.00 0.90 1.00
1S 1 0 0.00 0.05 0.90 1.00
2P 2 1 0.00 0.00 0.75 0.75
ATOM
# A program built with MPI starts under its launcher; a threaded build has none.
launch() { if command -v mpirun > /dev/null; then mpirun -n 1 "$@"; else "$@"; fi; }
launch ld1.x -in atom.in > atom.out || { cat atom.out; exit 1; }
test -s H.UPF
cat > molecule.in <<'QE'
&control
 calculation='scf', prefix='hydrogen', pseudo_dir='.', outdir='./scratch'
/
&system
 ibrav=1, celldm(1)=14.0, nat=2, ntyp=1, ecutwfc=25.0, ecutrho=100.0
/
&electrons
 conv_thr=1.0d-8
/
ATOMIC_SPECIES
H 1.008 H.UPF
ATOMIC_POSITIONS angstrom
H 3.00 3.00 3.00
H 3.74 3.00 3.00
K_POINTS gamma
QE
mkdir scratch
OMP_NUM_THREADS=2 launch pw.x -in molecule.in > molecule.out || { cat molecule.out; exit 1; }
grep -q 'convergence has been achieved' molecule.out
grep -q 'JOB DONE' molecule.out
awk '/^!.*total energy/ { if ($5 <= -3 || $5 >= -1.5) exit 1; found=1 } END { if (!found) exit 1 }' molecule.out
if [ "${SELFTEST_GPU:-0}" = 1 ]; then
    grep -q 'GPU acceleration is ACTIVE' molecule.out || { cat molecule.out; echo 'pw.x did not run on the GPU' >&2; exit 1; }
    printf '%s\n' 'Quantum ESPRESSO ran with GPU acceleration'
fi
printf '%s\n' 'Quantum ESPRESSO generated a hydrogen potential and converged the H2 SCF example'
