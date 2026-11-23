#!/bin/sh
set -eu
wise_id=lammps
. /opt/wise/lib/wise/feature.sh

wise_require_capability mpi
wise_require fftw
wise_require linear-algebra
list() { echo "$1" | tr ',' ' '; }
member() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
variant=${VARIANT:-cpu}
arch=${GPUARCH:-AMPERE80}
potentials=${POTENTIALS:-bundled}
extra=$(list "${EXTRAPACKAGES:-}")
disable=$(list "${DISABLEPACKAGES:-}")
case "$variant" in
    cpu) ;;
    cuda) wise_cuda || wise_fail "variant=cuda needs the CUDA base image" ;;
    *) wise_fail "unknown variant $variant" ;;
esac
case "$potentials" in none|bundled|all) ;; *) wise_fail "unknown potentials mode $potentials" ;; esac
! member KSPACE "$disable" || wise_fail "KSPACE is required and cannot be disabled"
for package in KOKKOS GPU; do
    ! member "$package" "$extra" || wise_fail "$package is chosen by variant (cuda builds KOKKOS; the native GPU package is never built)"
done
[ "$variant" = cpu ] || ! member INTEL "$extra" || wise_fail "INTEL cannot be built by nvcc_wrapper (variant=cuda)"

# Packages backed by a Feature (PACKAGE:feature; the Feature installs lib<feature>). Requested through
# extraPackages, they need that Feature; stack/test/stack.test.ts reads this line.
providers="PLUMED:plumed H5MD:hdf5 NETCDF:netcdf"
# Packages that fetch third-party code from the network (cmake/Modules/Packages of the pinned commit):
# always off, unless backed by a Feature above and requested.
downloading="KIM MACHDYN MBX MDI ML-HDNNP ML-PACE ML-QUIP ML-RUNNER PLUMED SCAFACOS VORONOI"
# Bundled packages off by default: INTEL only pays off with the Intel compiler.
off="INTEL"
provider() { # package -> backing Feature
    for entry in $providers; do [ "${entry%%:*}" != "$1" ] || { echo "${entry#*:}"; return 0; }; done
    return 1
}
backed() { # package: a Feature-backed package needs its Feature; a downloading one without a Feature fails
    if feature=$(provider "$1"); then wise_require "$feature" "LAMMPS package $1"
    elif member "$1" "$downloading"; then wise_fail "package $1 downloads third-party code and no Feature provides it yet"; fi
}
for package in $extra; do backed "$package"; done

wise_workdir
src=$WISE_WORK/src
build=$WISE_WORK/build
wise_fetch_git https://github.com/lammps/lammps.git 098ffdefa525cabc82272925de02e9884f58c657 "$src"

# Every bundled package (LAMMPS' presets all_on + nolib), none that downloads, KSPACE on FFTW3 with
# OpenMP threads from the fftw Feature, and never the native GPU package.
set -- -C "$src/cmake/presets/all_on.cmake" -C "$src/cmake/presets/nolib.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WISE_PREFIX" -DBUILD_SHARED_LIBS=ON \
    -DBUILD_MPI=ON -DMPI_C_COMPILER="$WISE_PREFIX/bin/mpicc" -DMPI_CXX_COMPILER="$WISE_PREFIX/bin/mpicxx" -DBUILD_OMP=ON \
    -DPKG_KSPACE=ON -DFFT=FFTW3 -DFFTW3_INCLUDE_DIR="$WISE_PREFIX/include" -DFFTW3_LIBRARY="$WISE_PREFIX/lib/libfftw3.so" \
    -DFFTW3_OMP_LIBRARY="$WISE_PREFIX/lib/libfftw3_omp.so" -DFFT_FFTW_THREADS=ON -DPKG_GPU=OFF -DPLUMED_MODE=shared
if [ "$potentials" = all ]; then set -- "$@" -DDOWNLOAD_POTENTIALS=ON; else set -- "$@" -DDOWNLOAD_POTENTIALS=OFF; fi
for package in $downloading $off; do member "$package" "$extra" || set -- "$@" -DPKG_"$package"=OFF; done
for package in $extra; do set -- "$@" -DPKG_"$package"=ON; done
for package in $disable; do set -- "$@" -DPKG_"$package"=OFF; done
if [ "$variant" = cuda ]; then
    # KOKKOS with the CUDA backend (OpenMP on the host); its FFTs run on cuFFT from the HPC SDK math_libs.
    # nvcc_wrapper compiles every package; INTEL relies on host compiler flags nvcc does not accept.
    set -- "$@" -DPKG_KOKKOS=ON -DKokkos_ENABLE_CUDA=ON -DKokkos_ENABLE_OPENMP=ON -DKokkos_ARCH_"$arch"=ON \
        -DFFT_KOKKOS=CUFFT -DCUDAToolkit_ROOT="$CUDA_HOME" -DCMAKE_PREFIX_PATH="${NVHPC_ROOT:?}/math_libs;$WISE_PREFIX" \
        -DCMAKE_CXX_COMPILER="$src/lib/kokkos/bin/nvcc_wrapper" -DPKG_INTEL=OFF
else
    set -- "$@" -DPKG_KOKKOS=OFF -DCMAKE_PREFIX_PATH="$WISE_PREFIX"
fi
# cmakeArgs is a space separated list by contract; no globbing while it is split.
set -f
# shellcheck disable=SC2086
set -- "$@" ${CMAKEARGS:-}
set +f
cmake -S "$src/cmake" -B "$build" "$@"

# Whatever the options said (cmakeArgs included), check what will actually be built.
cache=$build/CMakeCache.txt
on() { grep -q "^$1:BOOL=ON$" "$cache"; }
on PKG_KSPACE || wise_fail "KSPACE is required"
grep -q '^FFT:STRING=FFTW3$' "$cache" || wise_fail "KSPACE must use FFTW3 from the fftw Feature"
! on PKG_GPU || wise_fail "the native GPU package is never built; use variant=cuda (KOKKOS)"
if [ "$variant" = cuda ]; then on PKG_KOKKOS && on Kokkos_ENABLE_CUDA || wise_fail "variant=cuda needs KOKKOS with CUDA"
else ! on PKG_KOKKOS || wise_fail "variant=cpu does not build KOKKOS"; fi
enabled=
for entry in $providers; do enabled="$enabled ${entry%%:*}"; done
for package in $downloading $enabled; do
    if on "PKG_$package"; then backed "$package"; fi
done
downloads=$(sed -n 's/^\(DOWNLOAD_[A-Z0-9_]*\):BOOL=\(ON\|YES\|TRUE\|1\)$/\1/p' "$cache" | grep -vx DOWNLOAD_POTENTIALS | tr '\n' ' ' || true)
[ -z "$downloads" ] || wise_fail "LAMMPS would download third-party code ($downloads); add its package to the downloading list or provide it through a Feature"

cmake --build "$build" -j"$(nproc)"
cmake --install "$build" --strip
ldconfig
[ "$potentials" != none ] || rm -rf "$WISE_PREFIX/share/lammps/potentials"
wise_linked "$WISE_PREFIX/bin/lmp" "$WISE_PREFIX/lib/libmpi" "$WISE_PREFIX/lib/libfftw3" "$WISE_PREFIX/lib/libfftw3_omp"
[ "$variant" != cuda ] || wise_linked "$WISE_PREFIX/bin/lmp" libcufft
for entry in $providers; do
    if on "PKG_${entry%%:*}"; then wise_linked "$WISE_PREFIX/lib/liblammps.so" "$WISE_PREFIX/lib/lib${entry#*:}"; fi
done
wise_done
