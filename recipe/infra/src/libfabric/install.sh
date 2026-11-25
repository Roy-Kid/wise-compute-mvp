#!/bin/sh
set -eu
wise_id=libfabric
. /usr/local/lib/devcontainer-features/feature.sh

wise_require rdma
wise_workdir
cd "$WISE_WORK"
wise_fetch_tar https://github.com/ofiwg/libfabric/releases/download/v2.7.0/libfabric-2.7.0.tar.bz2 \
    366000427e194d4ce22e272519b608afbebb1fc9915bcf5da924157a8a47fe10 src
cd src
set -- --prefix="$WISE_PREFIX" --disable-static --enable-verbs --enable-efa --enable-rxm --enable-shm --enable-tcp
if wise_cuda; then
    set -- "$@" --with-cuda="$CUDA_HOME" --with-gdrcopy="${GDRCOPY_HOME:?}" --enable-cuda-dlopen --enable-gdrcopy-dlopen
fi
./configure "$@"
make -j"$(nproc)"
make install-strip
ldconfig
providers=$("$WISE_PREFIX/bin/fi_info" -l)
for provider in verbs efa shm tcp; do
    echo "$providers" | grep -q "^$provider:" || wise_fail "provider $provider was not built"
done
wise_done
