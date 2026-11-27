#!/bin/sh
set -eu
wise_id=asap3
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
asap3==3.13.11 --hash=sha256:4f878ce3e77520e92eba9faea8ed4b1a9f4baca40c2a213339ec31284dd3a0d5
REQ
# Asap builds its parallel version when it finds mpicxx on the PATH: the image's own, or none.
if wise_mpi; then PATH="$WISE_MPI_ROOT/bin:$PATH"; export PATH; fi
# The environment of the python Feature already holds setuptools and NumPy, which the build needs.
"${WISE_VENV:?}/bin/pip" install --no-cache-dir --require-hashes --no-deps --no-build-isolation --no-binary asap3 -r "$requirements"
# Found as a file: importing a parallel Asap starts MPI, which some MPI libraries only do under their launcher.
site=$("$WISE_VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_path("platlib"))')
module=$(find "$site" -name '_asap*.so' | head -n 1)
[ -n "$module" ] || wise_fail "the compiled Asap module was not installed"
if wise_mpi; then wise_mpi_linked "$module"; else wise_linked "$module" && wise_not_linked "$module" libmpi; fi
wise_done
