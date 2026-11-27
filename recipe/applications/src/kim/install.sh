#!/bin/sh
set -eu
wise_id=kim
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_workdir
wise_fetch_git https://github.com/openkim/kim-api.git e566ef57c6bb251f502d15e94d39b44eb56715f4 "$WISE_WORK/src"
# The KIM API has no MPI; GCC builds it on every base image, and models are compiled with the same compilers.
cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DCMAKE_Fortran_COMPILER=gfortran \
    -DKIM_API_BUILD_EXAMPLES=ON
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build"
ldconfig
"$WISE_PREFIX/bin/kim-api-collections-management" list | grep -q ex_model_Ar_P_Morse_07C \
    || wise_fail "the example models were not installed"
# kimpy serves the ASE calculator, and its build needs the setuptools of the materials-python Feature.
if wise_has materials-python; then
    # pybind11 first: the kimpy build imports it, like the setuptools and NumPy that the environment already holds.
    cat > "$WISE_WORK/build-requirements.txt" <<'REQ'
pybind11==3.1.0 --hash=sha256:b8488090f8acffbcb6b5d6a85571a6827a0a2981ffb75e5a0b27b87c4a6b7dd0
REQ
    cat > "$WISE_WORK/requirements.txt" <<'REQ'
kimpy==2.1.4 --hash=sha256:7287c4696e42f27fa32f93da67162de2a58d92b2d93a62efd7da33d595e878df
REQ
    pip=${WISE_VENV:?}/bin/pip
    "$pip" install --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$WISE_WORK/build-requirements.txt"
    CC=gcc CXX=g++ PKG_CONFIG_PATH="$WISE_PREFIX/lib/pkgconfig" "$pip" install --no-cache-dir \
        --require-hashes --no-deps --no-build-isolation --no-binary kimpy -r "$WISE_WORK/requirements.txt"
    module=$("$WISE_VENV/bin/python" -c 'import kimpy.model as m; print(m.__file__)')
    wise_linked "$module" libkim-api
fi
wise_done
