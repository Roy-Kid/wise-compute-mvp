#!/bin/sh
set -eu
wise_id=dftd3
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
dftd3==1.7.0 --hash=sha256:616e8c3b9d5777afc7a97df0f57696c5812c0ecd2aed708378ab581a472f0da1
# cffi carries the calls into the compiled library.
cffi==2.1.1 --hash=sha256:c1453022f490d2459a11819d83ad1d586e9ff65a12ac3e705ffebd46d3685dcf
pycparser==3.12 --hash=sha256:a076f3f489b39b43ed13563a1dafe42447445bec2e294154ec5c57fcdda4c85e
REQ
"${WISE_VENV:?}/bin/pip" install --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$requirements"
"$WISE_VENV/bin/pip" check
"$WISE_VENV/bin/python" -c 'from dftd3.ase import DFTD3'
wise_done
