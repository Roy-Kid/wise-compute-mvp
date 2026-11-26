#!/bin/sh
set -eu
wise_id=ucx
. /usr/local/lib/devcontainer-features/feature.sh

wise_require rdma
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://github.com/openucx/ucx/releases/download/v1.21.1/ucx-1.21.1.tar.gz \
    54f0d5471b0bbee28bb1dc10f72023d155026cefa2edcb8a36a282cfb26e93bd src
cd src
set -- --prefix="$WISE_PREFIX" --disable-static --enable-mt --with-verbs --with-rdmacm \
    --without-knem --without-xpmem --without-java --without-go
modules="ib rdmacm cma"
if wise_cuda; then
    # libcuda comes from the host driver at run time; the SDK stub satisfies the link.
    set -- "$@" --with-cuda="$CUDA_HOME" --with-gdrcopy="${GDRCOPY_HOME:?}" LDFLAGS="-L$CUDA_HOME/lib64/stubs"
    modules="$modules cuda cuda_gdrcopy"
fi
./contrib/configure-release "$@"
make -j"$(wise_build_jobs)"
make install-strip
for module in $modules; do
    test -e "$WISE_PREFIX/lib/ucx/libuct_$module.so" || wise_fail "transport $module was not built"
done
wise_done
