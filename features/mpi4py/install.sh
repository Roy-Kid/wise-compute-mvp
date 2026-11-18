#!/usr/bin/env bash
set -euo pipefail
command -v mpicc >/dev/null || { echo "[mpi4py] no mpicc: an MPI feature must be installed first" >&2; exit 1; }
# 强制源码构建，确保链接到镜像内的 MPI，而不是 wheel 自带的 MPI
/opt/wise/venv/bin/pip install --no-cache-dir --no-binary mpi4py "mpi4py==${VERSION}"
echo "mpi4py ${VERSION}" >> /opt/wise/install.log
