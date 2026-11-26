#!/bin/sh
# Consistency checks of a full delivery: wise-selftest --full, and the full-image scenario of the image build.
set -eu

variant=${1:?usage: delivery.sh cpu|cuda}
case "$variant" in cpu|cuda) ;; *) echo "unknown variant: $variant" >&2; exit 2 ;; esac
: "${WISE_VENV:?WISE_VENV is missing; the python Feature is not installed}"
wise_id=verify
. /usr/local/lib/devcontainer-features/feature.sh

fail() { echo "verify: $*" >&2; exit 1; }
# On the CUDA base CP2K runs on a GNU stack and MPI of its own, reached through the commands in /usr/local/bin.
cp2k_program=/usr/local/bin/cp2k.psmp
cp2k_stack=/usr/local/cp2k-deps
if [ -e "$cp2k_stack/run-env.sh" ]; then
    cp2k_program=$cp2k_stack/cp2k/bin/cp2k.psmp
    cp2k_ldd() (. "$cp2k_stack/run-env.sh" && ldd "$cp2k_program")
else
    cp2k_ldd() { ldd "$cp2k_program"; }
fi
# An empty entry in a search path means the current directory.
for path in "${LD_LIBRARY_PATH:-}" "${CPATH:-}" "${LIBRARY_PATH:-}" "$PATH"; do
    [ -z "$path" ] || case ":$path:" in *::*) fail "a search path includes the current directory: $path" ;; esac
done
for tool in lmp pw.x ph.x pw2wannier90.x wannier90.x cp2k.psmp packmol Multiwfn mpirun ucx_info nc-config h5pcc \
    conda uv rustc cargo node npm; do
    command -v "$tool"
done

# Interconnect: CPU builds UCX and OFI; CUDA uses the HPC-X UCX transport.
ompi=$(ompi_info --parsable --all)
for component in pml:ucx osc:ucx; do
    echo "$ompi" | grep -q "^mca:${component%%:*}:${component#*:}:" || fail "Open MPI lacks $component"
done
if [ "$variant" = cpu ]; then
    echo "$ompi" | grep -q '^mca:mtl:ofi:' || fail "Open MPI lacks OFI"
    for module in ib rdmacm cma; do test -e "/usr/local/lib/ucx/libuct_$module.so" || fail "UCX lacks $module"; done
    for provider in verbs shm tcp; do fi_info -l | grep -q "^$provider:" || fail "libfabric lacks $provider"; done
else
    [ "${WISE_BASE_MPI:-}" = openmpi ] || fail "the CUDA base must supply Open MPI"
    ucx_info -v
fi
# MPI in a container: shared memory needs room; the defaults (64 MiB) break intra-node transport.
shm=$(df -Pk /dev/shm | awk 'NR == 2 { print $2 }')
[ "$shm" -ge 1048576 ] || fail "/dev/shm is $((shm / 1024)) MiB; run with --shm-size=16g (or --ipc=host)"
# Ranks are bound to cores, threads stay next to their rank.
[ "$OMP_PLACES" = cores ] && [ "$OMP_PROC_BIND" = close ]
cores=$(lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l)
if [ "$cores" -ge 2 ]; then ranks=2; else ranks=1; fi
mpirun -n "$ranks" --report-bindings true 2>&1 | grep -q 'bound to' || fail "mpirun does not bind ranks"
# The two-rank checks below also run on a single core (CI runners with one hyper-threaded core).
if [ "$cores" -lt 2 ]; then
    export OMPI_MCA_rmaps_base_oversubscribe=1 PRTE_MCA_rmaps_default_mapping_policy=:oversubscribe
fi
# Parallel I/O and solvers.
[ "$(nc-config --has-parallel4)" = yes ] || fail "NetCDF-4 parallel I/O is off"
grep -q 'define H5_HAVE_PARALLEL 1' /usr/local/include/H5pubconf.h || fail "HDF5 is not parallel"
for lib in libfftw3 libfftw3f libfftw3_omp libfftw3f_omp libfftw3_mpi libfftw3f_mpi; do
    test -e "/usr/local/lib/$lib.so" || fail "FFTW lacks $lib"
done
for lib in /usr/local/lib/libelpa /usr/local/lib/libhdf5 /usr/local/lib/libscalapack; do
    ldd /usr/local/bin/pw.x | grep -q "$lib" || fail "pw.x does not link $lib"
done
for lib in libelpa_openmp libhdf5; do
    cp2k_ldd | grep -q "$lib" || fail "cp2k.psmp does not link $lib"
done
# One OpenMP runtime per process.
for binary in /usr/local/bin/lmp /usr/local/bin/pw.x; do
    [ "$(ldd "$binary" | grep -c 'libgomp\|libnvomp')" -le 1 ] || fail "$binary loads two OpenMP runtimes"
done
[ "$(cp2k_ldd | grep -c 'libgomp\|libnvomp')" -le 1 ] || fail "cp2k.psmp loads two OpenMP runtimes"

# Every MPI consumer uses the selected provider's library and launcher.
for binary in /usr/local/bin/lmp /usr/local/bin/pw.x \
    "$(MPI4PY_RC_INITIALIZE=0 "$WISE_VENV/bin/python" -c 'import mpi4py.MPI as m; print(m.__file__)')"; do
    wise_mpi_linked "$binary"
done
if [ -e "$cp2k_stack/run-env.sh" ]; then
    # CP2K's stack stays out of the image's PATH and loader cache, and loads nothing of the image's MPI.
    cp2k_ldd | awk '$1 ~ /^libmpi[.]so/ { print $3 }' | grep -q "^$cp2k_stack/install/openmpi-" \
        || fail "cp2k.psmp does not load the MPI of its own stack"
    ! cp2k_ldd | grep -q -e "$WISE_MPI_ROOT" -e /hpcx || fail "cp2k.psmp loads the image's MPI stack"
    ! ldconfig -p | grep -q "$cp2k_stack/" || fail "CP2K's stack is in the loader cache"
    case ":$PATH:" in *":$cp2k_stack/"*) fail "CP2K's stack is in PATH" ;; esac
    command -v cp2k-mpirun
else
    wise_mpi_linked "$cp2k_program"
fi
test "$(readlink -f "$(command -v mpirun)")" = "$(readlink -f "$WISE_MPI_ROOT/bin/mpirun")"

mpirun -n 2 "$WISE_VENV/bin/python" -c '
from mpi4py import MPI
level = MPI.Query_thread()
if level not in (MPI.THREAD_SERIALIZED, MPI.THREAD_MULTIPLE):
    raise RuntimeError(f"ELPA with OpenMP requires at least MPI_THREAD_SERIALIZED, got {level}")
assert MPI.COMM_WORLD.allreduce(1) == 2
'
# COSMA, SIRIUS and LIBXSMM are static, so ask CP2K itself.
cp2k_version=$(mktemp)
if [ "$variant" = cuda ] && [ "${WISE_VERIFY_GPU:-1}" != 1 ]; then
    # A CUDA build of CP2K stops at start-up without a device: read the feature names from its library.
    strings -a "$(cp2k_ldd | awk '/libcp2k.*=>/ {print $3; exit}')" > "$cp2k_version"
else
    cp2k.psmp --version > "$cp2k_version"
    cat "$cp2k_version"
fi
for feature in cosma sirius libxsmm spglib; do
    grep -qw "$feature" "$cp2k_version" || fail "CP2K lacks $feature"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
MPLCONFIGDIR="$work/matplotlib" MPLBACKEND=Agg "$WISE_VENV/bin/python" - <<'PY'
import MDAnalysis
import h5py
import matplotlib.pyplot
import numpy
import pandas
import phono3py
import phonopy
import pycalphad
import pyscf
import spglib
from ase import Atoms
from pymatgen.core import Lattice
from scipy.linalg import det

assert len(Atoms("Si")) == 1
assert Lattice.cubic(2).volume == 8
assert det(numpy.eye(2)) == 1
with h5py.File("materials.h5", "w") as output:
    output["result"] = pandas.Series([numpy.dot([2], [3])]).to_numpy()
with h5py.File("materials.h5", "r") as output:
    assert output["result"][0] == 6
PY
cat > in.lj <<'LAMMPS'
units lj
atom_style atomic
lattice fcc 0.8442
region box block 0 6 0 6 0 6
create_box 1 box
create_atoms 1 box
mass 1 1.0
velocity all create 1.44 87287 loop geom
pair_style lj/cut 2.5
pair_coeff 1 1 1.0 1.0 2.5
fix integrate all nve
run 50
print "$(pe:%.12f)" file pe-${ranks}.txt
LAMMPS
# Numerical consistency: the same trajectory on 1 and 2 ranks (different decompositions) agrees.
# Under mpirun also for one rank: a singleton start can hang in a container without a network.
mpirun -n 1 lmp -var ranks 1 -in in.lj -log none -screen none
mpirun -n 2 lmp -var ranks 2 -in in.lj -log none -screen none
awk 'NR == FNR { a = $1; next } { d = a - $1; if (d < 0) d = -d; s = a < 0 ? -a : a; exit !(d <= 1e-8 * s) }' \
    pe-1.txt pe-2.txt || fail "LAMMPS energies differ between 1 and 2 ranks: $(cat pe-1.txt) vs $(cat pe-2.txt)"
# KSPACE: PPPM on a charge-neutral CsCl-type lattice; its FFTs run on FFTW3 (cuFFT under KOKKOS on a GPU).
cat > in.pppm <<'LAMMPS'
units real
atom_style charge
lattice sc 4.0
region box block 0 6 0 6 0 6
create_box 2 box
create_atoms 1 box
lattice sc 4.0 origin 0.5 0.5 0.5
create_atoms 2 box
mass * 22.99
set type 1 charge 1.0
set type 2 charge -1.0
pair_style lj/cut/coul/long 8.0
pair_coeff * * 0.1 3.0
kspace_style pppm 1.0e-4
velocity all create 300.0 87287 loop geom
timestep 0.5
fix integrate all nve
run 20
LAMMPS
mpirun -n 2 lmp -in in.pppm -log none -screen none
# Parallel trajectory output through H5MD (HDF5) and NETCDF.
sed 's/^run 20$/dump h5 all h5md 10 traj.h5 position\ndump nc all netcdf 10 traj.nc id type x y z\nrun 20/' in.pppm > in.io
mpirun -n 2 lmp -in in.io -log none -screen none
test -s traj.h5 && test -s traj.nc
mpirun -n 1 lmp -h > lammps-help.txt
for package in KSPACE H5MD NETCDF OPENMP; do grep -qw "$package" lammps-help.txt || fail "LAMMPS lacks $package"; done
grep -q 'FFT library *= *FFTW3' lammps-help.txt || fail "LAMMPS KSPACE does not use FFTW3"
! grep -qw INTEL lammps-help.txt || fail "INTEL is off by default"

if [ "$variant" = cpu ]; then
    test -z "${CUDA_HOME:-}" && ! command -v nvcc >/dev/null
    exit
fi
grep -q 'KOKKOS package API:.*CUDA' lammps-help.txt
grep -q 'KOKKOS FFT library *= *cuFFT' lammps-help.txt
! grep -q 'GPU package API' lammps-help.txt || { echo "the native GPU package must not be built" >&2; exit 1; }
ldd /usr/local/bin/pw.x | grep -q libcufft
! ldd /usr/local/bin/pw.x | grep -q libgomp || fail "the GPU pw.x loads GCC's OpenMP runtime"
# Check the linked CUDA objects even on a builder without a GPU.
cp2k_library=$(cp2k_ldd | awk '/libcp2k.*=>/ {print $3; exit}')
for binary in /usr/local/bin/pw.x /usr/local/lib/liblammps.so /usr/local/lib/libelpa_openmp.so \
    "${cp2k_library:-$cp2k_program}"; do
    cuobjdump --list-elf "$binary" > architectures.txt
    grep -Eq '(^|[^[:alnum:]_])sm_120([^[:alnum:]_]|$)' architectures.txt || fail "$binary lacks sm_120 device code"
done
cp2k_ldd | grep -q libcudart
for feature in offload_cuda dbcsr_acc spla_gemm_offloading; do
    grep -qw "$feature" "$cp2k_version" || fail "CP2K lacks $feature"
done
! grep -q 'no_offload_' "$cp2k_version" || fail "CP2K keeps a GPU path on the CPU"
for lib in libcufft libcublas libcusolver; do
    cp2k_ldd | grep -q "$lib" || fail "cp2k.psmp does not link $lib"
done
for lib in libcublas libcusolver; do
    ldd /usr/local/lib/libelpa_openmp.so | grep -q "$lib" || fail "ELPA does not link $lib"
done
echo "$ompi" | grep -Eq '(^|:)mpi_built_with_cuda_support:value:true$' || fail "Open MPI is not CUDA-aware"
[ "${WISE_VERIFY_GPU:-1}" = 1 ] || exit 0
# Run on the device: KOKKOS must initialize the GPU and finish both runs, PPPM with cuFFT.
mpirun -n 1 lmp -k on g 1 -sf kk -var ranks 1 -in in.lj -log none -screen none
mpirun -n 1 lmp -k on g 1 -sf kk -in in.pppm -log none -screen none
