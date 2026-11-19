#!/bin/sh
set -eu

if command -v cp2k >/dev/null; then cp2k --version; else cp2k.psmp --version; fi
