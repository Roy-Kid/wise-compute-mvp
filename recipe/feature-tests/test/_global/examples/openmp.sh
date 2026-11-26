#!/bin/sh
set -eu
test "$OMP_NUM_THREADS" = 1
test "$OMP_PLACES" = cores
test "$OMP_PROC_BIND" = close
wise_id=openmp-test
. /usr/local/lib/devcontainer-features/feature.sh
available=$(env -u OMP_NUM_THREADS -u OMP_THREAD_LIMIT nproc)
if [ "$available" -gt 32 ]; then available=32; fi
test "$(OMP_THREAD_LIMIT=1 wise_build_jobs)" = "$available"
for flags in "$CFLAGS" "$CXXFLAGS" "$FFLAGS" "$FCFLAGS"; do
    case " $flags " in *' -march=x86-64-v3 '*) ;; *) exit 1;; esac
done
cat > sum.c <<'C'
#include <omp.h>
int main(void) {
    int sum = 0, threads = 0;
    #pragma omp parallel reduction(+:threads)
    { threads += 1; }
    #pragma omp parallel for reduction(+:sum)
    for (int i = 1; i <= 100; i++) sum += i;
    return threads != 2 || sum != 5050;
}
C
cat > sum.f90 <<'FORTRAN'
program reduction
  use omp_lib
  implicit none
  integer :: i, total, threads
  total = 0
  threads = 0
  !$omp parallel reduction(+:threads)
  threads = threads + 1
  !$omp end parallel
  !$omp parallel do reduction(+:total)
  do i = 1, 100
    total = total + i
  end do
  !$omp end parallel do
  if (threads /= 2 .or. total /= 5050) stop 1
end program
FORTRAN
# These flags come from the Feature's containerEnv.
# shellcheck disable=SC2086
gcc $CFLAGS -fopenmp sum.c -o sum-c
# shellcheck disable=SC2086
g++ $CXXFLAGS -x c++ -fopenmp sum.c -o sum-cxx
# shellcheck disable=SC2086
gfortran $FCFLAGS -fopenmp sum.f90 -o sum-fortran
for executable in sum-c sum-cxx sum-fortran; do
    OMP_NUM_THREADS=2 "./$executable"
done
printf '%s\n' 'OpenMP C, C++ and Fortran two-thread reductions passed'
