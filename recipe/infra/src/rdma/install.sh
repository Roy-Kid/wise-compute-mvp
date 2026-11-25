#!/bin/sh
set -eu
wise_id=rdma
. /usr/local/lib/devcontainer-features/feature.sh

wise_apt rdma-core ibverbs-providers ibverbs-utils libibverbs-dev librdmacm-dev libnuma-dev
for header in infiniband/verbs.h rdma/rdma_cma.h numa.h; do test -e "/usr/include/$header"; done
wise_done
