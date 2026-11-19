#!/bin/sh
set -eu

dpkg-query -W libopenblas-dev liblapack-dev libfftw3-dev
