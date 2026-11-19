#!/bin/sh
set -eu

"$WISE_VENV/bin/python" -c 'import numpy; assert numpy.dot([2], [3]) == 6'
