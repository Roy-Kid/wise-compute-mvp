#!/bin/sh
set -eu
wise_id=gpaw
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

variant=${VARIANT:-cpu}
arch=${CUDAARCH:-80}
case "$variant" in
    cpu) ;;
    cuda)
        wise_cuda || wise_fail "variant=cuda needs the CUDA base image"
        echo "$arch" | grep -qx '[1-9][0-9]*' || wise_fail "cudaArch is a compute capability such as 80, not $arch"
        ;;
    *) wise_fail "unknown variant $variant" ;;
esac
wise_workdir
# GPAW reads its build settings from this file. ScaLAPACK needs an MPI and is used when installed.
# ELPA is left out: GPAW 25.7.0 calls C functions that ELPA has since renamed.
config=$WISE_WORK/siteconfig.py
cat > "$config" <<SITE
prefix = '$WISE_PREFIX'
libraries = ['xc', 'openblas', 'fftw3']
library_dirs = [prefix + '/lib']
runtime_library_dirs = [prefix + '/lib']
include_dirs = [prefix + '/include']
extra_compile_args += ['-O3', '-fopenmp']
extra_link_args += ['-fopenmp']
fftw = True
SITE
if wise_mpi; then
    printf '%s\n' 'mpi = True' "compiler = '$WISE_MPI_ROOT/bin/mpicc'" >> "$config"
    if wise_has scalapack; then printf '%s\n' 'scalapack = True' "libraries += ['scalapack']" >> "$config"; fi
else
    printf '%s\n' 'mpi = False' "compiler = 'gcc'" >> "$config"
fi
if [ "$variant" = cuda ]; then
    cat >> "$config" <<SITE
gpu = True
gpu_target = 'cuda'
gpu_compiler = '$CUDA_HOME/bin/nvcc'
gpu_compile_args = ['-O3', '-gencode', 'arch=compute_$arch,code=sm_$arch']
gpu_include_dirs = ['${NVHPC_ROOT:?}/math_libs/include']
include_dirs += ['$CUDA_HOME/include', '$NVHPC_ROOT/math_libs/include']
library_dirs += ['$CUDA_HOME/lib64', '$NVHPC_ROOT/math_libs/lib64']
libraries += ['cudart', 'cublas', 'stdc++']
SITE
fi
requirements=$WISE_WORK/requirements.txt
cat > "$requirements" <<'REQ'
gpaw==25.7.0 --hash=sha256:93ac829bba36be74eab0d7deef5eb798613c04edbce196837208d206cf39c431
gpaw-data==1.2.1 --hash=sha256:5ded7ef43ca9b53332ad2fe9d7951dd36e6fba221662227fd24abf748b904c27
REQ
if [ "$variant" = cuda ]; then
    cat >> "$requirements" <<'REQ'
cupy-cuda12x==14.2.0 --hash=sha256:f82141761f2c81905d49387464ae29438887956d99063381c93a1d5d1b7d32e8
REQ
fi
pip=${WISE_VENV:?}/bin/pip
# The environment of the python Feature already holds setuptools and NumPy, which the build needs.
GPAW_CONFIG=$config "$pip" install --no-cache-dir --require-hashes --no-deps --no-build-isolation --no-binary gpaw -r "$requirements"
module=$("$WISE_VENV/bin/python" -c 'import _gpaw; print(_gpaw.__file__)')
if wise_mpi; then wise_mpi_linked "$module" "$WISE_PREFIX/lib/libxc" "$WISE_PREFIX/lib/libfftw3" libopenblas
else wise_linked "$module" "$WISE_PREFIX/lib/libxc" "$WISE_PREFIX/lib/libfftw3" libopenblas && wise_not_linked "$module" libmpi; fi
! wise_mpi || ! wise_has scalapack || wise_linked "$module" "$WISE_PREFIX/lib/libscalapack"
[ "$variant" != cuda ] || wise_linked "$module" libcudart libcublas
wise_done
