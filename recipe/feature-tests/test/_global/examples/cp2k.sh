#!/bin/sh
set -eu
cat > molecule.inp <<'CP2K'
&GLOBAL
  PROJECT hydrogen
  RUN_TYPE ENERGY
&END GLOBAL
&FORCE_EVAL
  METHOD QUICKSTEP
  &DFT
    BASIS_SET_FILE_NAME BASIS_MOLOPT
    POTENTIAL_FILE_NAME GTH_POTENTIALS
    &MGRID
      CUTOFF 200
      REL_CUTOFF 30
    &END MGRID
    &SCF
      EPS_SCF 1.0E-6
      MAX_SCF 35
    &END SCF
    &XC
      &XC_FUNCTIONAL PBE
      &END XC_FUNCTIONAL
    &END XC
  &END DFT
  &SUBSYS
    &CELL
      ABC 10 10 10
    &END CELL
    &COORD
      H 4.63 5.00 5.00
      H 5.37 5.00 5.00
    &END COORD
    &KIND H
      BASIS_SET DZVP-MOLOPT-SR-GTH
      POTENTIAL GTH-PBE-q1
    &END KIND
  &END SUBSYS
&END FORCE_EVAL
CP2K
# On the CUDA base CP2K has an MPI of its own, started with cp2k-mpirun.
launcher=mpirun
! command -v cp2k-mpirun >/dev/null || launcher=cp2k-mpirun
"$launcher" -n 1 cp2k.psmp -i molecule.inp > molecule.out || { cat molecule.out; exit 1; }
grep -q 'SCF run converged' molecule.out
awk '/ENERGY\| Total FORCE_EVAL/ { if ($NF <= -1.4 || $NF >= -0.8) exit 1; found=1 } END { if (!found) exit 1 }' molecule.out
printf '%s\n' 'CP2K converged the H2 energy example using installed basis and potential data'
