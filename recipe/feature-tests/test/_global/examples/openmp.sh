#!/bin/sh
set -eu
test "$OMP_PLACES" = cores
test "$OMP_PROC_BIND" = close
wise_id=openmp-test
. /usr/local/lib/devcontainer-features/feature.sh
# One thread per rank where the image has an MPI, every core where it has none.
if wise_mpi; then test "$OMP_NUM_THREADS" = 1 && test "$OPENBLAS_NUM_THREADS" = 1
else test -z "${OMP_NUM_THREADS:-}${OPENBLAS_NUM_THREADS:-}"; fi
available=$(env -u OMP_NUM_THREADS -u OMP_THREAD_LIMIT nproc)
if [ "$available" -gt 32 ]; then available=32; fi
test "$(OMP_THREAD_LIMIT=1 wise_build_jobs)" = "$available"
for flags in "$CFLAGS" "$CXXFLAGS" "$FFLAGS" "$FCFLAGS"; do
    case " $flags " in *' -march=x86-64-v3 '*) ;; *) exit 1;; esac
done
printf '%s\n' 'The image sets the OpenMP defaults and the x86-64-v3 compiler flags'
