#!/usr/bin/env bash
set -euo pipefail
/opt/wise/venv/bin/pip install --no-cache-dir "numpy==${VERSION}"
echo "numpy ${VERSION}" >> /opt/wise/install.log
