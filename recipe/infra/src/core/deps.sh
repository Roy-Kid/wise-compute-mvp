# What a Feature may know about the image it installs into: the registry of installed Features and the
# capabilities they or the base image provide. Loaded by feature.sh.
#
# Dev Container's dependsOn installs what a Feature always needs, in order; nothing here repeats that. The
# queries below are for what dependsOn cannot say: a Feature needed only with an option, one used when it
# happens to be there, and a capability several Features or the base image can provide. A Feature queried
# here must be in the installsAfter of the Feature that asks, which `wisehub feature check` verifies; for
# that the arguments are written out, not taken from variables.
# shellcheck shell=sh

WISE_REGISTRY=${WISE_REGISTRY:-$WISE_PREFIX/share/devcontainer-features}
# The version this Feature registers, read while the working directory is still the Feature's own.
wise_self_version=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$(dirname "$0")/devcontainer-feature.json" 2>/dev/null | head -n 1)

wise_sdk() { # since 4. number: the lowest SDK this script works with
    case "${1:-}" in ''|*[!0-9]*) wise_fail "wise_sdk takes the number of an SDK" ;; esac
    [ "$WISE_SDK" -ge "$1" ] \
        || wise_fail "needs Feature SDK $1 and this image has SDK $WISE_SDK; install the core Feature again first"
}

# --- Registry -------------------------------------------------------------------------------------
wise_has() { [ -f "$WISE_REGISTRY/$1" ]; } # since 3. feature: whether it is installed
wise_version() { # since 4. feature: prints its version; nothing for one that an SDK before 4 registered
    wise_has "$1" || wise_fail "asks for the version of $1, which is not installed"
    sed -n 's/^version=//p' "$WISE_REGISTRY/$1"
}
wise_require() { # since 3. feature [why]: needed under a condition that the script tests itself
    wise_has "$1" || wise_fail "needs the $1 Feature${2:+ ($2)}; add it to the delivery"
}
wise_require_if() { # since 3. value feature [why]: needed when a boolean option is true
    [ "$1" != true ] || wise_require "$2" "${3:-}"
}
wise_provider() { # since 3. capability: prints the implementation from the base or an installed Feature
    capability_key=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
    if base_provider=$(printenv "WISE_BASE_$capability_key") && [ -n "$base_provider" ]; then
        printf '%s\n' "$base_provider"
    else
        [ -e "$WISE_REGISTRY/provides/$1" ] && cat "$WISE_REGISTRY/provides/$1"
    fi
}
wise_require_capability() { # since 3. capability: some Feature provides it (e.g. mpi: openmpi or mpich)
    wise_provider "$1" >/dev/null || wise_fail "the base image or a selected Feature must provide $1"
}
wise_mpi() { # since 4. the image has an MPI; without one the Features build their threaded programs
    wise_provider mpi >/dev/null
}
wise_provide() { # since 3. capability: claim an exclusive capability; a second provider fails
    if current=$(wise_provider "$1"); then wise_fail "$1 is already provided by $current; select one"; fi
    mkdir -p "$WISE_REGISTRY/provides"
    echo "$wise_id" > "$WISE_REGISTRY/provides/$1"
}
wise_done() { # since 3. register this Feature as installed, with its version and the SDK that installed it
    [ -n "$wise_self_version" ] || wise_fail "found no version in the devcontainer-feature.json next to $0"
    ldconfig
    mkdir -p "$WISE_REGISTRY/provides"
    printf 'id=%s\nversion=%s\nsdk=%s\n' "$wise_id" "$wise_self_version" "$WISE_SDK" > "$WISE_REGISTRY/$wise_id"
}
