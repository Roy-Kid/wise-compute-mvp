# WiseHub Feature SDK. Every Feature's install.sh starts with
#   . /opt/wise/lib/wise/feature.sh <id>
# and ends with wise_done. Features learn about each other only through the registry below, by id or by
# capability, never by probing another Feature's files; their requirements are the wise_require* calls,
# which stack/test/stack.test.ts reads to check dependsOn/installsAfter and every delivery.
# shellcheck shell=sh

WISE_PREFIX=/opt/wise
# nvfortran builds of Fortran libraries on the CUDA base (Fortran modules are compiler specific).
WISE_NVHPC_PREFIX=$WISE_PREFIX/nvhpc
WISE_REGISTRY=$WISE_PREFIX/share/wise/features
wise_id=${1:?usage: . feature.sh <feature id>}

wise_fail() { echo "$wise_id: $*" >&2; exit 1; }

# --- Registry -------------------------------------------------------------------------------------
wise_has() { [ -e "$WISE_REGISTRY/$1" ]; } # feature
wise_require() { # feature [why]: an installed Feature this one needs
    wise_has "$1" || wise_fail "needs the $1 Feature${2:+ ($2)}; add it to the delivery"
}
wise_require_if() { # value feature [why]: needed when a boolean option is true
    [ "$1" != true ] || wise_require "$2" "${3:-}"
}
wise_provider() { # capability: prints the Feature providing it
    [ -e "$WISE_REGISTRY/provides/$1" ] && cat "$WISE_REGISTRY/provides/$1"
}
wise_require_capability() { # capability: some Feature provides it (e.g. mpi: openmpi or mpich)
    wise_provider "$1" >/dev/null || wise_fail "the delivery must select a Feature providing $1"
}
wise_provide() { # capability: claim an exclusive capability; a second provider fails
    if current=$(wise_provider "$1"); then wise_fail "$1 is already provided by $current; select one"; fi
    echo "$wise_id" > "$WISE_REGISTRY/provides/$1"
}
wise_done() { # register this Feature as installed
    ldconfig
    mkdir -p "$WISE_REGISTRY/provides"
    : > "$WISE_REGISTRY/$wise_id"
}

# --- Sources: pinned, verified, no history ----------------------------------------------------------
wise_workdir() { # sets WISE_WORK, removed on exit
    WISE_WORK=$(mktemp -d)
    trap 'rm -rf "$WISE_WORK"' EXIT
}
wise_fetch_tar() { # url sha256 dir: download, verify and unpack one release archive into dir
    mkdir -p "$3"
    curl --fail --location --silent --show-error --retry 3 --proto '=https' "$1" -o "$3.archive"
    echo "$2  $3.archive" | sha256sum --check --quiet || wise_fail "checksum mismatch for $1"
    tar -xf "$3.archive" -C "$3" --strip-components=1
    rm -f "$3.archive"
}
wise_fetch_git() { # url commit dir [submodule...|--all]: exactly one commit, depth 1, no tags
    url=$1 commit=$2 dir=$3; shift 3
    git init --quiet "$dir"
    git -C "$dir" fetch --quiet --depth 1 --no-tags "$url" "$commit"
    git -C "$dir" checkout --quiet FETCH_HEAD
    if [ "${1:-}" = --all ]; then git -C "$dir" submodule update --quiet --init --depth 1
    elif [ $# -gt 0 ]; then git -C "$dir" submodule update --quiet --init --depth 1 -- "$@"; fi
}
wise_apt() { # package...: install from the base image's Ubuntu snapshot
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    rm -rf /var/lib/apt/lists/*
}

# --- Checks -----------------------------------------------------------------------------------------
wise_linked() { # binary pattern...: resolves every library and links each pattern
    libs=$(ldd "$1") || wise_fail "ldd $1 failed"
    if echo "$libs" | grep -q "not found"; then echo "$libs" >&2; wise_fail "$1 has unresolved libraries"; fi
    bin=$1; shift
    for pattern; do echo "$libs" | grep -q "$pattern" || wise_fail "$bin does not link $pattern"; done
}
wise_not_linked() { # binary pattern...
    bin=$1; shift
    for pattern; do ! ldd "$bin" | grep -q "$pattern" || wise_fail "$bin must not link $pattern"; done
}

# --- Toolchains -------------------------------------------------------------------------------------
wise_cuda() { [ -n "${CUDA_HOME:-}" ]; } # whether the base image is the CUDA one
wise_nvfortran_env() { # MPI wrappers drive the HPC SDK compilers; -tp matches the x86-64-v3 baseline
    command -v nvfortran >/dev/null || wise_fail "nvfortran needs the CUDA base image with the NVIDIA HPC SDK"
    export OMPI_CC=nvc OMPI_CXX=nvc++ OMPI_FC=nvfortran MPICH_CC=nvc MPICH_CXX=nvc++ MPICH_FC=nvfortran
    export CFLAGS="-O2 -tp=haswell" CXXFLAGS="-O2 -tp=haswell" FFLAGS="-O2 -tp=haswell" FCFLAGS="-O2 -tp=haswell"
    WISE_SDK_LIB=${NVHPC_ROOT:?}/compilers/lib # the SDK's BLAS/LAPACK, built without GCC's OpenMP
}
