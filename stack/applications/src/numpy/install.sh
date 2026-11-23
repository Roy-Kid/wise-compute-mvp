#!/bin/sh
set -eu
wise_id=numpy
. /opt/wise/lib/wise/feature.sh

wise_require python
requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
cat > "$requirements" <<'REQ'
numpy==2.4.6 \
    --hash=sha256:90f9849678c75fe7afa2d348ac842c168b0a4d3d61919687216dfc547976d853 \
    --hash=sha256:5f9fb9157b4ce2971008323afe46053787b526ef624fea915b261468a8421a0f
REQ
"${WISE_VENV:?}/bin/pip" install --no-cache-dir --require-hashes --only-binary numpy -r "$requirements"
wise_done
