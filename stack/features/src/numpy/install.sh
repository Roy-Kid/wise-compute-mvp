#!/bin/sh
set -eu

: "${WISE_VENV:?install the python Feature before numpy}"
"$WISE_VENV/bin/pip" install --no-cache-dir "numpy==${VERSION}"
