#!/usr/bin/env bash
set -euo pipefail
# 原子化：只负责 Python 本身。若已安装则跳过（共享依赖复用的可观测证据）。
if [ -x /opt/wise/venv/bin/python ]; then echo "[python] already present, skip"; exit 0; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends python3 python3-venv python3-dev build-essential pkg-config ca-certificates
python3 -m venv /opt/wise/venv
/opt/wise/venv/bin/pip install --no-cache-dir -U pip
mkdir -p /opt/wise && echo "python $(python3 -V)" >> /opt/wise/install.log
rm -rf /var/lib/apt/lists/*
