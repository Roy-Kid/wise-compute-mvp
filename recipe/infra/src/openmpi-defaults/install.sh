#!/bin/sh
set -eu
wise_id=openmpi-defaults
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

# Open MPI takes a single name in OMPI_MCA_pml: "ucx,ob1" only ever selects UCX and fails where UCX finds no device.
# The empty value set by this Feature means no preference.
wise_require_capability mpi
[ "$(wise_provider mpi)" = openmpi ] || wise_fail "Open MPI is not the MPI of this image"
wise_done
