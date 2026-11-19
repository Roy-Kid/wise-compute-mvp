#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends quantum-espresso
rm -rf /var/lib/apt/lists/*
