#!/bin/sh
set -eu

# WISE_VENV comes from this Feature's containerEnv, which the build applies before install.sh runs.
: "${WISE_VENV:?WISE_VENV must be set by the python Feature metadata}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    python3 python3-venv python3-dev build-essential pkg-config ca-certificates
rm -rf /var/lib/apt/lists/*
python3 -m venv "$WISE_VENV"
