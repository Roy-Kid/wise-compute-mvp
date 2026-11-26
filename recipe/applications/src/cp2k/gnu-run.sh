#!/bin/sh
# CP2K on the CUDA base runs on its own GNU stack and MPI. Its programs are reached through commands in
# $WISE_PREFIX/bin that set that environment, so the rest of the image keeps a single MPI in PATH and in the
# loader's cache.

# deps prefix: write the environment, the commands, and check what the installed program loads.
cp2k_gnu_install_commands() (
    deps=$1
    prefix=$2
    mpi=$(echo "$deps"/install/openmpi-*)
    [ -x "$mpi/bin/mpirun" ] || wise_fail "the CP2K toolchain built no Open MPI"
    libraries=$(find "$deps/install" "$prefix" -maxdepth 3 -type d \( -name lib -o -name lib64 \) | sort | paste -sd: -)
    cat > "$deps/run-env.sh" <<ENV
# The environment of CP2K's own GNU stack; sourced by the cp2k commands in $WISE_PREFIX/bin.
unset OPAL_PREFIX OMPI_MCA_pml OMPI_CC OMPI_CXX OMPI_FC
export PATH="$mpi/bin:\$PATH"
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:$libraries:$CUDA_HOME/lib64:$NVHPC_ROOT/math_libs/lib64\${CP2K_EXTRA_LIBRARY_PATH:+:\$CP2K_EXTRA_LIBRARY_PATH}"
ENV
    # The image's mpirun belongs to another MPI and would start unconnected ranks: each program refuses it.
    guard='[ -z "${OMPI_COMM_WORLD_SIZE:-}" ] || [ -n "${PRTE_LAUNCHED:-}" ] || { echo "$0: start CP2K with cp2k-mpirun; mpirun belongs to the other MPI of this image" >&2; exit 1; }'
    for program in "$prefix"/bin/*; do
        [ -f "$program" ] && [ -x "$program" ] || continue
        cp2k_gnu_command "$deps" "$program" "$WISE_PREFIX/bin/$(basename "$program")" "$guard"
    done
    cp2k_gnu_command "$deps" "$mpi/bin/mpirun" "$WISE_PREFIX/bin/cp2k-mpirun" ''

    # libcuda comes with the driver of the node; a builder without a GPU has the SDK's compatibility copy.
    loaded=$(CP2K_EXTRA_LIBRARY_PATH="$CUDA_HOME/compat" && . "$deps/run-env.sh" && ldd "$prefix/bin/cp2k.psmp")
    echo "$loaded" | grep -q 'not found' && wise_fail "cp2k.psmp misses libraries: $(echo "$loaded" | grep 'not found')"
    echo "$loaded" | awk '$1 ~ /^libmpi[.]so/ { print $3 }' | grep -q "^$mpi/" \
        || wise_fail "cp2k.psmp does not load the MPI of its own stack"
    ! echo "$loaded" | grep -q -e "$HPCX_HOME" -e "$WISE_MPI_ROOT" -e '/hpcx' \
        || wise_fail "cp2k.psmp loads the image's MPI stack"
    ! echo "$loaded" | grep -Eq "=> $WISE_PREFIX/lib/lib(fftw3|scalapack|elpa|hdf5|netcdf)" \
        || wise_fail "cp2k.psmp loads libraries built for the image's MPI"
    echo "$loaded" | awk '$1 ~ /^libgomp[.]so/ { print $3 }' | grep -q '^/usr/lib/' \
        || wise_fail "cp2k.psmp does not load GNU OpenMP"
    echo "$loaded" | grep -q libcudart || wise_fail "cp2k.psmp does not link the CUDA runtime"
)

cp2k_gnu_command() { # deps program command guard
    cat > "$3" <<COMMAND
#!/bin/sh
# Runs on CP2K's own GNU stack and MPI; start parallel runs with cp2k-mpirun.
$4
. "$1/run-env.sh"
exec "$2" "\$@"
COMMAND
    chmod 0755 "$3"
}
