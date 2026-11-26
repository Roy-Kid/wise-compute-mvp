#!/bin/bash
set -eu
example=$1
examples=$(cd "$(dirname "$0")" && pwd)
export HOME=/tmp OPENBLAS_NUM_THREADS=1 OMP_DYNAMIC=false
if [[ $MATERIALS_TEST_VARIANT == cuda && $MATERIALS_TEST_GPU == 0 ]]; then
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$CUDA_HOME/compat"
fi
source "$examples/../dev-container-features-test-lib"
read -r -a features <<< "$MATERIALS_TEST_FEATURES"
for feature in "${features[@]}"; do
    check "$feature registered" test -f "/usr/local/share/devcontainer-features/$feature" || true
done
# Allow two-rank tests on a runner with access to only one physical core.
export OMPI_MCA_rmaps_base_oversubscribe=1 PRTE_MCA_rmaps_default_mapping_policy=:oversubscribe
run_example() (
    work=$(mktemp -d) || exit
    trap 'rm -rf "$work"' EXIT
    cd "$work" || exit
    timeout "$2" sh "$examples/$1.sh" "$MATERIALS_TEST_VARIANT" </dev/null
)
test_example() {
    local name=$1 seconds=${2:-300}
    if [[ ${3:-} == gpu && $MATERIALS_TEST_VARIANT == cuda && $MATERIALS_TEST_GPU == 0 ]]; then
        echo "$name CUDA example skipped unless FEATURE_TEST_GPU=1"
    else
        check "$name example" run_example "$name" "$seconds" || true
    fi
}
if [[ $MATERIALS_TEST_VARIANT == cuda && ( $example == openmp || $example == full ) ]]; then
    test_example cuda-preflight 60
fi
if [[ $example == full ]]; then
    export WISE_VERIFY_GPU=$MATERIALS_TEST_GPU
    test_example delivery 900
    for example in openmp toolchains mpi libraries python packmol wannier90 lammps; do
        test_example "$example"
    done
    test_example quantum-espresso 300 gpu
    test_example cp2k 300 gpu
elif [[ -n $example ]]; then
    test_example "$example" 300 "${2:-}"
fi
reportResults
