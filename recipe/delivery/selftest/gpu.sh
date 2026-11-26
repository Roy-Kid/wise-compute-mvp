#!/bin/sh
set -eu
# The visible GPU, and the driver and compute capability the caller requires of it.
nvidia-smi -L
driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
capability=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
if [ -n "${SELFTEST_MIN_DRIVER:-}" ]; then
    [ "${driver%%.*}" -ge "$SELFTEST_MIN_DRIVER" ] \
        || { echo "the image requires NVIDIA driver $SELFTEST_MIN_DRIVER or newer (found $driver)" >&2; exit 1; }
fi
if [ -n "${SELFTEST_GPU_CAPABILITY:-}" ]; then
    [ "$capability" = "$SELFTEST_GPU_CAPABILITY" ] \
        || { echo "the image is compiled for compute capability $SELFTEST_GPU_CAPABILITY (found $capability)" >&2; exit 1; }
fi
printf '%s\n' "The GPU has compute capability $capability on driver $driver"
