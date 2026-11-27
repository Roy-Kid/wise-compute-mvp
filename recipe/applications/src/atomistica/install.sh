#!/bin/sh
set -eu
wise_id=atomistica
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
atomistica==1.2.7 --hash=sha256:0945a18fe7cc861519ad5e5aa43fd4541c71f82fa4d0557ce6a58894471753d7
REQ
"${WISE_VENV:?}/bin/pip" install --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$requirements"
# No pip check: the wheel's metadata names a pip release as a requirement, which nothing needs at run time.
"$WISE_VENV/bin/python" -c 'import atomistica; atomistica.Tersoff'
wise_done
