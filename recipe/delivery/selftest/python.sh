#!/bin/sh
set -eu
export MPLCONFIGDIR=$PWD/matplotlib MPLBACKEND=Agg
python3 - <<'PY'
import MDAnalysis
import h5py
import matplotlib.pyplot
import numpy as np
import pandas
import phono3py
import phonopy
import pycalphad
import pyscf
import spglib
from ase.build import bulk
from ase.calculators.emt import EMT
from pymatgen.core import Lattice
from scipy.linalg import det

atoms = bulk('Cu')
atoms.calc = EMT()
energy = atoms.get_potential_energy()
assert np.isfinite(energy) and abs(energy) < 1
assert Lattice.cubic(2).volume == 8 and det(np.eye(2)) == 1
with h5py.File('results.h5', 'w') as output:
    output['energy'] = pandas.Series([energy]).to_numpy()
with h5py.File('results.h5') as output:
    assert output['energy'][0] == energy
PY
# The BLAS inside NumPy gives the same product on one thread and on the image's default number of threads.
python3 - <<'PY'
import os, subprocess, sys
code = "import numpy as np; a = np.random.default_rng(7).random((600, 600)); print(repr(float((a @ a).trace())))"
default = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout
single = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True,
                        env={**os.environ, "OPENBLAS_NUM_THREADS": "1"}).stdout
assert abs(float(default) - float(single)) <= 1e-9 * abs(float(single)), (default, single)
PY
# mpi4py, where the image has an MPI.
if command -v mpirun > /dev/null && python3 -c 'import mpi4py' 2> /dev/null; then
    mpirun -n 2 python3 -c 'from mpi4py import MPI; c = MPI.COMM_WORLD; assert c.size == 2 and c.allreduce(c.rank) == 1'
fi
