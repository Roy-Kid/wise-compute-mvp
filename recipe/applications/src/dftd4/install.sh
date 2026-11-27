#!/bin/sh
set -eu
wise_id=dftd4
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
dftd4==4.3.1 --hash=sha256:9084dfad8dfb815215f9320ab983fb586e552e1f872d83e96140b8e383b7d2ce
# cffi carries the calls into the compiled library.
cffi==2.1.1 --hash=sha256:c1453022f490d2459a11819d83ad1d586e9ff65a12ac3e705ffebd46d3685dcf
pycparser==3.12 --hash=sha256:a076f3f489b39b43ed13563a1dafe42447445bec2e294154ec5c57fcdda4c85e
REQ
"${WISE_VENV:?}/bin/pip" install --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$requirements"
"$WISE_VENV/bin/pip" check
"$WISE_VENV/bin/python" -c 'from dftd4.ase import DFTD4'
wise_done
