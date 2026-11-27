#!/bin/sh
set -eu
wise_id=materials-python
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

pip=${WISE_VENV:?}/bin/pip
"$pip" install --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$(dirname "$0")/requirements.txt"
"$pip" check
wise_done
