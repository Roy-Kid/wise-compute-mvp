#!/bin/sh
set -eu
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
# The image's compiler flags, when it sets any.
# shellcheck disable=SC2086
gcc ${CFLAGS:-} -fopenmp sum.c -o sum-c
# shellcheck disable=SC2086
g++ ${CXXFLAGS:-} -x c++ -fopenmp sum.c -o sum-cxx
# shellcheck disable=SC2086
gfortran ${FCFLAGS:-} -fopenmp sum.f90 -o sum-fortran
for executable in sum-c sum-cxx sum-fortran; do
    OMP_NUM_THREADS=2 "./$executable"
done
printf '%s\n' 'OpenMP C, C++ and Fortran two-thread reductions passed'
