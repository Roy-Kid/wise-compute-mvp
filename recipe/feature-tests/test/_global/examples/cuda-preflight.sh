#!/bin/sh
set -eu
wise_id=cuda-preflight
. /usr/local/lib/devcontainer-features/feature.sh
. "$(dirname "$0")/lammps-cuda.sh"
lammps_cuda_file_table_available /proc/sys/fs/file-nr
# Reproduce a file-table failure after compilation has started.
(
    cmake() {
        printf '%s\n' "$*" >> compile-attempts
        if [ "$3" = -j12 ]; then
            printf '%s\n' 'fatal error: header.hpp: Too many open files in system' >&2
            return 2
        fi
        [ "$3" = -j6 ]
    }
    lammps_cuda_build existing-tree 12 compile.log
    printf '%s\n' '--build existing-tree -j12' '--build existing-tree -j6' > expected-attempts
    diff -u expected-attempts compile-attempts
)
linker_flags=$(lammps_cuda_link_flags)
lammps_cuda_link_probe g++ "$linker_flags"
# Both CUDA compilers in the base must emit native RTX PRO 5000 Blackwell code.
printf '__global__ void probe(int *value) { *value = 1; }\n' > blackwell.cu
nvcc -arch=sm_120 -c blackwell.cu -o blackwell.o
cat > blackwell.f90 <<'FORTRAN'
subroutine probe(values, count)
  integer :: count, i, values(count)
  !$acc parallel loop copyout(values)
  do i = 1, count
    values(i) = i
  end do
end subroutine
FORTRAN
nvfortran -acc -gpu=cc120,cuda12.9 -c blackwell.f90 -o blackwell-fortran.o
for object in blackwell.o blackwell-fortran.o; do
    cuobjdump --list-elf "$object" > "$object.architectures"
    grep -Eq '(^|[^[:alnum:]_])sm_120([^[:alnum:]_]|$)' "$object.architectures" \
        || wise_fail "$object lacks sm_120 device code"
done
