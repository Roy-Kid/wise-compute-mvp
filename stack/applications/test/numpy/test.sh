#!/bin/sh
set -eu

/opt/wise/venv/bin/python -c 'import numpy; assert numpy.dot([2], [3]) == 6'
