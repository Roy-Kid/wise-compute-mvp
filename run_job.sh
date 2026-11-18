#!/usr/bin/env bash
# Execution Plane：只用 docker + 镜像 digest/ID，不需要 Dev Container CLI，也不读 Feature 依赖。
set -euo pipefail
IMAGE=${1:?usage: run_job.sh <image@digest|image-id> [nproc]}
NP=${2:-2}
# 只通过 OCI 镜像元数据了解环境（例如 MPI 实现），据此选择启动参数
CAPS=$(docker image inspect -f '{{ index .Config.Labels "io.wisehub.capabilities" }}' "$IMAGE")
echo "[exec] image=$IMAGE capabilities=$CAPS"
EXTRA=()
case "$CAPS" in *'"mpi": "openmpi"'*) EXTRA=(-e OMPI_ALLOW_RUN_AS_ROOT=1 -e OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1);; esac
docker run --rm "${EXTRA[@]}" -v "$(cd "$(dirname "$0")" && pwd)/jobs:/job:ro" "$IMAGE" \
  mpirun -n "$NP" /opt/wise/venv/bin/python /job/hello_mpi.py
