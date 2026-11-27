#!/bin/sh
set -eu
wise_id=deepmd-kit
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

variant=${VARIANT:-cpu}
arch=${CUDAARCH:-80}
case "$variant" in
    cpu) index=https://download.pytorch.org/whl/cpu ;;
    cuda)
        wise_cuda || wise_fail "variant=cuda needs the CUDA base image"
        echo "$arch" | grep -qx '[1-9][0-9]*' || wise_fail "cudaArch is a compute capability such as 80, not $arch"
        index=https://download.pytorch.org/whl/cu126
        ;;
    *) wise_fail "unknown variant $variant" ;;
esac
pip=${WISE_VENV:?}/bin/pip
# PyTorch and the other requirements of DeePMD-kit and of its build, as locked wheels.
"$pip" install --no-cache-dir --require-hashes --only-binary=:all: --no-deps --extra-index-url "$index" \
    -r "$(dirname "$0")/requirements-$variant.txt"
requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
deepmd-kit==3.2.0 --hash=sha256:0a3b57d350c2fba26005e9696be1d598d2aea3a76f0fa947d3f63f96220f3530
REQ
# The source build compiles DeePMD-kit's library for the PyTorch installed above and, when the image has
# one, for its MPI; the published wheels bring an MPICH of their own. TensorFlow is not installed.
export DP_VARIANT="$variant" DP_ENABLE_PYTORCH=1 DP_ENABLE_TENSORFLOW=0 CC=gcc CXX=g++
if [ "$variant" = cuda ]; then
    # The library needs the CUDA driver, which the SDK supplies on GPU-less builders.
    export CUDAToolkit_ROOT="$CUDA_HOME" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$CUDA_HOME/compat"
    # PyTorch's CMake files would compile each CUDA source for every architecture of its wheel, at about
    # two minutes per architecture and file. The list takes capabilities as 8.0 or 12.0.
    export TORCH_CUDA_ARCH_LIST="${arch%?}.${arch#"${arch%?}"}"
fi
if wise_mpi; then PATH="$WISE_MPI_ROOT/bin:$PATH"; export PATH; fi
"$pip" install --no-cache-dir --require-hashes --no-deps --no-build-isolation --no-binary deepmd-kit -r "$requirements"
"$pip" check
# PyTorch must load DeePMD-kit's own library; its libtorch is found only once PyTorch is imported, so ldd cannot tell.
timeout 300 "$WISE_VENV/bin/python" -c 'from deepmd.pt.cxx_op import ENABLE_CUSTOMIZED_OP as loaded; assert loaded' \
    || wise_fail "PyTorch cannot load DeePMD-kit's library"
site=$("$WISE_VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_path("platlib"))')
library=$site/deepmd/lib/libdeepmd_op_pt.so
if wise_mpi; then ldd "$library" | grep -q 'libmpi' || wise_fail "DeePMD-kit's library does not link the image's MPI"; fi
[ "$variant" != cuda ] || ldd "$library" | grep -q 'libdeepmd_dyn_cudart\|libcudart' || wise_fail "DeePMD-kit's library has no CUDA kernels"
wise_done
