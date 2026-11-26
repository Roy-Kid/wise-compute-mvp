#!/bin/bash
# Runs one scenario's checks with the Dev Container CLI test library: the checks of this image build kept
# next to this file, and the tests of materials-selftest that can run in this container.
set -eu
example=$1
examples=$(cd "$(dirname "$0")" && pwd)
gpu=0
if [[ $MATERIALS_TEST_VARIANT == cuda ]] && nvidia-smi -L &> /dev/null; then gpu=1; fi
export HOME=/tmp OMP_DYNAMIC=false WISE_VERIFY_GPU=$gpu
if [[ $MATERIALS_TEST_VARIANT == cuda && $gpu == 0 ]]; then
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$CUDA_HOME/compat"
fi
# Allow two-rank tests on a runner with access to only one physical core.
export OMPI_MCA_rmaps_base_oversubscribe=1 PRTE_MCA_rmaps_default_mapping_policy=:oversubscribe
selftest=$examples/selftest/materials-selftest
source "$examples/../dev-container-features-test-lib"
read -r -a features <<< "$MATERIALS_TEST_FEATURES"
for feature in "${features[@]}"; do
    check "$feature registered" test -f "/usr/local/share/devcontainer-features/$feature" || true
done
build_check() ( # name seconds
    work=$(mktemp -d) || exit
    trap 'rm -rf "$work"' EXIT
    cd "$work" || exit
    timeout "$2" sh "$examples/$1.sh" "$MATERIALS_TEST_VARIANT" </dev/null
)
if [[ $MATERIALS_TEST_VARIANT == cuda && ( $example == openmp || $example == full ) ]]; then
    check "cuda-preflight build check" build_check cuda-preflight 60 || true
fi
if [[ $example == full ]]; then
    # The delivery check is about the one MPI of an image; the SMP delivery has none.
    [[ $MATERIALS_TEST_VARIANT == smp ]] || check "delivery build check" build_check delivery 900 || true
    check "openmp build check" build_check openmp 60 || true
    plan=$("$selftest" --plan)
elif [[ -n $example ]]; then
    [[ ! -f $examples/$example.sh ]] || check "$example build check" build_check "$example" 60 || true
    plan=$("$selftest" --plan "$example" 2> /dev/null) || plan=
fi
for name in ${plan:-}; do
    check "$name example" "$selftest" --run "$name" || true
done
reportResults
