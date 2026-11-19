#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends libscalapack-openmpi-dev
rm -rf /var/lib/apt/lists/*
