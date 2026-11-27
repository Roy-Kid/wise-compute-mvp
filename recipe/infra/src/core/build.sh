# Build helpers of the WiseHub Feature SDK: sources, system packages, link checks and toolchains. They keep no
# state in the image. Loaded by feature.sh.
# shellcheck shell=sh

# --- Sources: pinned, verified, no history ----------------------------------------------------------
# One dropped connection must not cost hours of compilation.
export PIP_RETRIES=10 PIP_DEFAULT_TIMEOUT=60
wise_retry() { # since 3. command...: up to five attempts with a growing pause
    attempt=1
    until "$@"; do
        [ "$attempt" -lt 5 ] || wise_fail "failed after $attempt attempts: $*"
        echo "$wise_id: attempt $attempt failed, retrying: $*" >&2
        sleep "$((attempt * ${WISE_RETRY_PAUSE:-15}))"
        attempt=$((attempt + 1))
    done
}
wise_download() { # since 3. url sha256 file
    wise_retry curl --fail --location --silent --show-error --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
        --proto '=https' "$1" -o "$3"
    echo "$2  $3" | sha256sum --check --quiet || wise_fail "checksum mismatch for $1"
}
wise_workdir() { # since 3. sets WISE_WORK, removed on exit
    WISE_WORK=$(mktemp -d)
    trap 'rm -rf "$WISE_WORK"' EXIT
}
wise_fetch_tar() { # since 3. url sha256 dir: download, verify and unpack one release archive into dir
    mkdir -p "$3"
    wise_download "$1" "$2" "$3.archive"
    tar -xf "$3.archive" -C "$3" --strip-components=1
    rm -f "$3.archive"
}
wise_fetch_git() { # since 3. url commit dir [submodule...|--all]: exactly one commit, depth 1, no tags
    url=$1 commit=$2 dir=$3; shift 3
    git init --quiet "$dir"
    wise_retry git -C "$dir" fetch --quiet --depth 1 --no-tags "$url" "$commit"
    git -C "$dir" checkout --quiet FETCH_HEAD
    if [ "${1:-}" = --all ]; then wise_retry git -C "$dir" submodule update --quiet --init --depth 1
    elif [ $# -gt 0 ]; then wise_retry git -C "$dir" submodule update --quiet --init --depth 1 -- "$@"; fi
}
wise_apt() { # since 3. package...: install from the base image's Ubuntu snapshot
    # A failed index download is only a warning unless asked otherwise.
    wise_retry env DEBIAN_FRONTEND=noninteractive apt-get -o APT::Update::Error-Mode=any update
    wise_retry env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    rm -rf /var/lib/apt/lists/*
}

# --- Checks -----------------------------------------------------------------------------------------
wise_linked() { # since 3. binary pattern...: resolves every library and links each pattern
    libs=$(ldd "$1") || wise_fail "ldd $1 failed"
    if echo "$libs" | grep -q "not found"; then echo "$libs" >&2; wise_fail "$1 has unresolved libraries"; fi
    bin=$1; shift
    for pattern; do echo "$libs" | grep -q "$pattern" || wise_fail "$bin does not link $pattern"; done
}
wise_not_linked() { # since 3. binary pattern...
    bin=$1; shift
    for pattern; do ! ldd "$bin" | grep -q "$pattern" || wise_fail "$bin must not link $pattern"; done
}
wise_mpi_linked() { # since 3. binary [other library patterns...]
    mpi_binary=$1; shift
    wise_linked "$mpi_binary" 'libmpi' "$@"
    mpi_library=$(ldd "$mpi_binary" | awk '$1 ~ /^libmpi(ch)?[.]so([.]|$)/ { print $3 }')
    [ -n "$mpi_library" ] && [ -e "$WISE_MPI_ROOT/lib/libmpi.so" ] \
        && [ "$(readlink -f "$mpi_library")" = "$(readlink -f "$WISE_MPI_ROOT/lib/libmpi.so")" ] \
        || wise_fail "$mpi_binary does not link the MPI from $WISE_MPI_ROOT"
}

# --- Toolchains -------------------------------------------------------------------------------------
wise_build_jobs() { # since 3.
    # The image's OpenMP settings are for running the compiled software.
    env -u OMP_NUM_THREADS OMP_THREAD_LIMIT=32 nproc
}

wise_cuda() { [ -n "${CUDA_HOME:-}" ]; } # since 3. whether the base image is the CUDA one
wise_nvfortran_env() { # since 3. MPI wrappers drive the HPC SDK compilers; -tp matches the x86-64-v3 baseline
    command -v nvfortran >/dev/null || wise_fail "nvfortran needs the CUDA base image with the NVIDIA HPC SDK"
    export CC=nvc CXX=nvc++ FC=nvfortran F77=nvfortran F90=nvfortran
    export OMPI_CC=nvc OMPI_CXX=nvc++ OMPI_FC=nvfortran MPICH_CC=nvc MPICH_CXX=nvc++ MPICH_FC=nvfortran
    export CFLAGS="-O2 -tp=haswell" CXXFLAGS="-O2 -tp=haswell" FFLAGS="-O2 -tp=haswell" FCFLAGS="-O2 -tp=haswell"
    export F77FLAGS="$FFLAGS" F90FLAGS="$FFLAGS"
}
