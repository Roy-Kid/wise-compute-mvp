#!/bin/sh
set -eu

: "${WISE_VENV:?WISE_VENV must be set by the python Feature}"
requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
numpy==2.5.5 \
    --hash=sha256:704d819265e5d1064d932968e9ee85fff2103ccc78c05b878c06943ba27b8507 \
    --hash=sha256:5cddc243c75114ba845f01b1f87aca1572dbf7b6c2d88636ed3e1d2bccd7f1bf
REQ
"$WISE_VENV/bin/pip" install --no-cache-dir --require-hashes --only-binary numpy -r "$requirements"
