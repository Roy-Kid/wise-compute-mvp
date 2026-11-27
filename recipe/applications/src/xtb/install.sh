#!/bin/sh
set -eu
wise_id=xtb
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_workdir
# The release source archive holds every subproject, so the build fetches nothing.
wise_fetch_tar https://github.com/grimme-lab/xtb/releases/download/v6.8.0/xtb-6.8.0-source.tar.xz \
    12a91ba662eb88d966febd2bb9936e20fa19c8e0258ba0d8a75efb02a1c6bcc6 "$WISE_WORK/src"
# xtb has no MPI; GCC builds it on every base image.
cmake -S "$WISE_WORK/src" -B "$WISE_WORK/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_C_COMPILER=gcc -DCMAKE_Fortran_COMPILER=gfortran -DBLA_VENDOR=OpenBLAS \
    -DWITH_OpenMP=ON -DWITH_TBLITE=ON -DWITH_CPCMX=ON -DWITH_TESTS=OFF -DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build "$WISE_WORK/build" -j"$(wise_build_jobs)"
cmake --install "$WISE_WORK/build"
wise_linked "$WISE_PREFIX/bin/xtb" libopenblas libgomp
test -d "$WISE_PREFIX/share/xtb" || wise_fail "the xtb parameter files were not installed"
if wise_has python && wise_has numpy; then
    requirements=$WISE_WORK/requirements.txt
    cat > "$requirements" <<'REQ'
tblite==0.8.0 --hash=sha256:e82fece754c5423eca7d49e2c9a328f66df0386b075893590007a4a51a744f73
# cffi carries the calls into the compiled library.
cffi==2.1.1 --hash=sha256:c1453022f490d2459a11819d83ad1d586e9ff65a12ac3e705ffebd46d3685dcf
pycparser==3.12 --hash=sha256:a076f3f489b39b43ed13563a1dafe42447445bec2e294154ec5c57fcdda4c85e
REQ
    "${WISE_VENV:?}/bin/pip" install --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$requirements"
    "$WISE_VENV/bin/python" -c 'import tblite.interface'
fi
wise_done
