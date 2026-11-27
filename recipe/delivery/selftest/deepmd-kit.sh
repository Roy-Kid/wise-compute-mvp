#!/bin/sh
set -eu
# A few frames of eight argon atoms with Lennard-Jones energies and forces from ASE: enough to train a
# very small deep potential for a few steps, freeze it and evaluate it through the ASE calculator.
cat > data.py <<'PY'
import os
import numpy as np
from ase import Atoms
from ase.calculators.lj import LennardJones

rng = np.random.default_rng(2026)
grid = np.array([[i, j, k] for i in range(2) for j in range(2) for k in range(2)]) * 3.5 + 0.9
frames = {'coord': [], 'box': [], 'energy': [], 'force': []}
for _ in range(8):
    atoms = Atoms('Ar8', positions=grid + rng.normal(0, 0.1, grid.shape), cell=[7.0, 7.0, 7.0], pbc=True)
    atoms.calc = LennardJones(sigma=3.4, epsilon=0.0104, rc=3.4)
    frames['coord'].append(atoms.positions.ravel())
    frames['box'].append(atoms.cell.array.ravel())
    frames['energy'].append(atoms.get_potential_energy())
    frames['force'].append(atoms.get_forces().ravel())
os.makedirs('data/set.000')
for name, values in frames.items():
    np.save(f'data/set.000/{name}.npy', np.array(values))
with open('data/type.raw', 'w') as file:
    file.write('0\n' * 8)
with open('data/type_map.raw', 'w') as file:
    file.write('Ar\n')
PY
cat > input.json <<'JSON'
{
  "model": {
    "type_map": ["Ar"],
    "descriptor": {"type": "se_e2_a", "rcut": 3.4, "rcut_smth": 0.5, "sel": [12], "neuron": [4, 8], "axis_neuron": 4, "seed": 1},
    "fitting_net": {"neuron": [8, 8], "seed": 1}
  },
  "learning_rate": {"type": "exp", "start_lr": 0.001, "stop_lr": 0.0001, "decay_steps": 5},
  "loss": {"type": "ener", "start_pref_e": 1, "limit_pref_e": 1, "start_pref_f": 1, "limit_pref_f": 1, "start_pref_v": 0, "limit_pref_v": 0},
  "training": {
    "training_data": {"systems": ["data"], "batch_size": 1},
    "numb_steps": 10, "seed": 1, "disp_freq": 5, "save_freq": 10
  }
}
JSON
cat > evaluate.py <<'PY'
import sys
import numpy as np
from ase import Atoms
from deepmd.calculator import DP

if sys.argv[1] == 'gpu':
    # On the device: the PyTorch backend of DeePMD-kit chooses CUDA when PyTorch sees a GPU.
    import torch
    from deepmd.pt.utils.env import DEVICE
    assert torch.cuda.is_available() and DEVICE.type == 'cuda', DEVICE
coord = np.load('data/set.000/coord.npy')[0].reshape(-1, 3)
atoms = Atoms('Ar8', positions=coord, cell=[7.0, 7.0, 7.0], pbc=True)
atoms.calc = DP(model='model.pth')
energy, forces = atoms.get_potential_energy(), atoms.get_forces()
assert np.isfinite(energy) and forces.shape == (8, 3) and np.isfinite(forces).all(), (energy, forces)
PY
export OMP_NUM_THREADS=2 DP_INTRA_OP_PARALLELISM_THREADS=2 DP_INTER_OP_PARALLELISM_THREADS=1
python3 data.py
# DeePMD-kit imports mpi4py when it is installed, and an MPI program starts under its launcher.
launch() { if command -v mpirun > /dev/null; then mpirun -n 1 "$@"; else "$@"; fi; }
launch dp --pt train input.json > train.out 2>&1 || { cat train.out; exit 1; }
launch dp --pt freeze -o model.pth > freeze.out 2>&1 || { cat freeze.out; exit 1; }
test -s model.pth || { cat freeze.out; echo 'DeePMD-kit wrote no frozen model' >&2; exit 1; }
if [ "${SELFTEST_GPU:-0}" = 1 ] && python3 -c 'import torch, sys; sys.exit(not torch.backends.cuda.is_built())'; then
    launch python3 evaluate.py gpu > evaluate.out 2>&1 || { cat evaluate.out; echo 'DeePMD-kit did not run on the GPU' >&2; exit 1; }
    printf '%s\n' 'DeePMD-kit trained and evaluated the model on the GPU'
else
    launch python3 evaluate.py cpu > evaluate.out 2>&1 || { cat evaluate.out; exit 1; }
fi
printf '%s\n' 'DeePMD-kit trained, froze and evaluated a small deep potential through its ASE calculator'
