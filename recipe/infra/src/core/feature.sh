# WiseHub Feature SDK. Every Feature's install.sh starts with
#   wise_id=<id>
#   . /usr/local/lib/devcontainer-features/feature.sh
#   wise_sdk <the lowest SDK the script works with>
# and ends with wise_done. An image keeps the SDK that built it, so a script written for a later one says
# so and stops there instead of taking a missing function for a condition that is false.
# deps.sh holds what a Feature may know about the image, build.sh the helpers for building.
# shellcheck shell=sh

# Raised by one whenever a function is added or changes; each function names the SDK it is in since.
WISE_SDK=4
WISE_PREFIX=/usr/local
WISE_MPI_ROOT=${WISE_MPI_ROOT:-$WISE_PREFIX}
: "${wise_id:?set wise_id before sourcing feature.sh}"

wise_fail() { echo "$wise_id: $*" >&2; exit 1; } # since 3. message

# The checks of feature-tests bring the repository's SDK and point here at their copy.
WISE_SDK_DIR=${WISE_SDK_DIR:-$WISE_PREFIX/lib/devcontainer-features}
. "$WISE_SDK_DIR/deps.sh"
. "$WISE_SDK_DIR/build.sh"
