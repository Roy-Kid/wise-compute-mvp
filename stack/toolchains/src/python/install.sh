#!/bin/sh
set -eu
. /opt/wise/lib/wise/feature.sh python

# WISE_VENV comes from this Feature's containerEnv, which the build applies before install.sh runs.
: "${WISE_VENV:?WISE_VENV must be set by the python Feature metadata}"
wise_apt \
    python3 python3-venv python3-dev build-essential pkg-config ca-certificates
python3 -m venv "$WISE_VENV"
wise_done
