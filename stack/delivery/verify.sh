#!/bin/sh
# Acceptance for a delivered image, run inside it as an unprivileged user:
#   docker run --rm -i --user 65534:65534 --network none --tmpfs /tmp:mode=1777 --shm-size=2g \
#     --entrypoint /bin/sh IMAGE -s cpu|cuda < stack/delivery/verify.sh
# For cuda, run on a GPU node with --gpus 1 to exercise the GPU paths; WISE_VERIFY_GPU=0 skips them.
set -eu

variant=${1:?usage: verify.sh cpu|cuda}
case "$variant" in cpu|cuda) ;; *) echo "unknown variant: $variant" >&2; exit 2 ;; esac
: "${WISE_VENV:?WISE_VENV is missing; the python Feature is not installed}"

fail() { echo "verify: $*" >&2; exit 1; }
for tool in lmp pw.x ph.x pw2wannier90.x wannier90.x cp2k.psmp packmol mpirun ucx_info fi_info nc-config h5pcc \
    conda uv rustc cargo node npm; do
    command -v "$tool"
done

# Interconnect: Open MPI carries UCX and OFI; UCX has InfiniBand/RoCE; libfabric has verbs and shm.
ompi=$(ompi_info --parsable --all)
for component in pml:ucx osc:ucx mtl:ofi; do
    echo "$ompi" | grep -q "^mca:${component%%:*}:${component#*:}:" || fail "Open MPI lacks $component"
done
for module in ib rdmacm cma; do test -e "/opt/wise/lib/ucx/libuct_$module.so" || fail "UCX lacks $module"; done
for provider in verbs shm tcp; do fi_info -l | grep -q "^$provider:" || fail "libfabric lacks $provider"; done
# MPI in a container: shared memory needs room; the defaults (64 MiB) break intra-node transport.
shm=$(df -Pk /dev/shm | awk 'NR == 2 { print $2 }')
[ "$shm" -ge 1048576 ] || fail "/dev/shm is $((shm / 1024)) MiB; run with --shm-size=16g (or --ipc=host)"
# Ranks are bound to cores, threads stay next to their rank.
[ "$OMP_PLACES" = cores ] && [ "$OMP_PROC_BIND" = close ]
mpirun -n 2 --report-bindings true 2>&1 | grep -q 'bound to' || fail "mpirun does not bind ranks"
# Parallel I/O and solvers.
[ "$(nc-config --has-parallel4)" = yes ] || fail "NetCDF-4 parallel I/O is off"
grep -q 'define H5_HAVE_PARALLEL 1' /opt/wise/include/H5pubconf.h || fail "HDF5 is not parallel"
for lib in libfftw3 libfftw3f libfftw3_omp libfftw3f_omp libfftw3_mpi libfftw3f_mpi; do
    test -e "/opt/wise/lib/$lib.so" || fail "FFTW lacks $lib"
done
qe_libs=/opt/wise/lib
[ "$variant" = cpu ] || qe_libs=/opt/wise/nvhpc/lib
for lib in "$qe_libs/libelpa" "$qe_libs/libhdf5" "$qe_libs/libscalapack"; do
    ldd /opt/wise/bin/pw.x | grep -q "$lib" || fail "pw.x does not link $lib"
done
for lib in libelpa_openmp libhdf5 libcosma libsirius; do
    ldd /opt/wise/bin/cp2k.psmp | grep -q "$lib" || fail "cp2k.psmp does not link $lib"
done
# One OpenMP runtime per process.
for binary in /opt/wise/bin/lmp /opt/wise/bin/pw.x /opt/wise/bin/cp2k.psmp; do
    [ "$(ldd "$binary" | grep -c 'libgomp\|libnvomp')" -le 1 ] || fail "$binary loads two OpenMP runtimes"
done

# One MPI: every MPI binary resolves libmpi from /opt/wise, and nothing else provides mpirun.
for binary in /opt/wise/bin/lmp /opt/wise/bin/pw.x /opt/wise/bin/cp2k.psmp \
    "$("$WISE_VENV/bin/python" -c 'import mpi4py.MPI as m; print(m.__file__)')"; do
    ldd "$binary" | grep -q '/opt/wise/lib/libmpi' || { echo "$binary does not link /opt/wise/lib/libmpi" >&2; exit 1; }
    ! ldd "$binary" | grep -q 'not found' || { ldd "$binary" >&2; exit 1; }
done
test "$(command -v mpirun)" = /opt/wise/bin/mpirun

"$WISE_VENV/bin/python" -c 'import numpy; assert numpy.dot([2], [3]) == 6'
mpirun -n 2 "$WISE_VENV/bin/python" -c 'from mpi4py import MPI; assert MPI.COMM_WORLD.allreduce(1) == 2'
cp2k.psmp --version

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
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
lmp -var ranks 1 -in in.lj -log none -screen none
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
lmp -h > lammps-help.txt
for package in KSPACE H5MD NETCDF OPENMP; do grep -qw "$package" lammps-help.txt || fail "LAMMPS lacks $package"; done
grep -q 'FFT library *= *FFTW3' lammps-help.txt || fail "LAMMPS KSPACE does not use FFTW3"
! grep -qw INTEL lammps-help.txt || fail "INTEL is off by default"

if [ "$variant" = cpu ]; then
    test -z "${CUDA_HOME:-}" && ! command -v nvcc >/dev/null
    exit
fi
grep -q 'KOKKOS package API:.*CUDA' lammps-help.txt
grep -q 'KOKKOS FFT library *= *CUFFT' lammps-help.txt
! grep -q 'GPU package API' lammps-help.txt || { echo "the native GPU package must not be built" >&2; exit 1; }
ldd /opt/wise/bin/pw.x | grep -q libcufft
! ldd /opt/wise/bin/pw.x | grep -q libgomp || fail "the GPU pw.x loads GCC's OpenMP runtime"
ldd /opt/wise/bin/cp2k.psmp | grep -q libcudart
echo "$ompi" | grep -q '^mpi_built_with_cuda_support:value:true$' || fail "Open MPI is not CUDA-aware"
for module in cuda cuda_gdrcopy; do test -e "/opt/wise/lib/ucx/libuct_$module.so" || fail "UCX lacks $module"; done
[ "${WISE_VERIFY_GPU:-1}" = 1 ] || exit 0
nvidia-smi -L
# CUDA 12.9 needs driver >= 575 natively; data-center GPUs on older drivers run through the forward
# compatibility package (WISE_CUDA_COMPAT=1 accepts that).
driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
[ "${driver%%.*}" -ge 575 ] || [ "${WISE_CUDA_COMPAT:-0}" = 1 ] \
    || fail "driver $driver is older than 575 (CUDA 12.9); set WISE_CUDA_COMPAT=1 on data-center GPUs with forward compatibility"
# Run on the device: KOKKOS must initialize the GPU and finish both runs, PPPM with cuFFT.
lmp -k on g 1 -sf kk -in in.lj -log none -screen none
lmp -k on g 1 -sf kk -in in.pppm -log none -screen none
