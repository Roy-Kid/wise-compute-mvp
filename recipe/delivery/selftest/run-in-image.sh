#!/bin/sh
# Runs materials-selftest from this directory inside a container of an image, on the machine that will
# run the image. Nothing is installed in the image; the tests and their logs stay outside it.
#
#   sh run-in-image.sh IMAGE [materials-selftest options and tests]
#
# Uses every GPU when the host has nvidia-smi. Logs and result.json go to SELFTEST_LOGS (default
# ./selftest-logs). CONTAINER_ENGINE selects docker (default) or podman. To check the GPU against what the
# image was compiled for, set SELFTEST_MIN_DRIVER and SELFTEST_GPU_CAPABILITY, for example 575 and 12.0.
set -eu
[ $# -ge 1 ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
image=$1; shift
here=$(cd "$(dirname "$0")" && pwd)
logs=${SELFTEST_LOGS:-$PWD/selftest-logs}
mkdir -p "$logs"
logs=$(cd "$logs" && pwd)
set -- --logs /selftest-logs --json /selftest-logs/result.json "$@"
if command -v nvidia-smi > /dev/null && nvidia-smi -L > /dev/null 2>&1; then
    set -- --gpus all "$image" /selftest/materials-selftest "$@"
else
    set -- "$image" /selftest/materials-selftest "$@"
fi
status=0
# As root with a shell as entry point: the logs folder is the caller's, and an image's own entry point
# may be a service. /tmp, because an image may name a temporary directory that only its service creates.
"${CONTAINER_ENGINE:-docker}" run --rm --shm-size=2g --user 0:0 --entrypoint sh -e TMPDIR=/tmp -v "$here:/selftest:ro" -v "$logs:/selftest-logs" \
    -e SELFTEST_MIN_DRIVER -e SELFTEST_GPU_CAPABILITY "$@" || status=$?
echo "logs and result.json are in $logs"
exit "$status"
