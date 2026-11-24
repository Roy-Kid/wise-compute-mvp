#!/bin/sh
# Strong-scaling benchmark of a delivered image, single or multi node. Prints one CSV row per run:
#   case,ranks,threads,seconds,speedup,efficiency
#
#   sh benchmark.sh [--ranks "1 2 4 8"] [--threads N] [--hostfile FILE] [--gpu] CASE...
#
# CASE is lammps-lj (LJ liquid, 256k atoms), lammps-pppm (charged lattice, PPPM on FFTW3 or cuFFT), or
# pw:INPUT / cp2k:INPUT for a Quantum ESPRESSO or CP2K input such as AUSURF112 or H2O-64 from their
# benchmark suites. --hostfile spreads ranks over the nodes it lists (Open MPI syntax); --gpu runs
# LAMMPS with KOKKOS on one GPU per rank. Run the container with --shm-size, and for multi node with
# --network=host --device=/dev/infiniband --ulimit memlock=-1.
set -eu

ranks="1 2 4"
threads=1
hostfile=
gpu=0
while [ $# -gt 0 ]; do
    case "$1" in
        --ranks) ranks=$2; shift 2 ;;
        --threads) threads=$2; shift 2 ;;
        --hostfile) hostfile=$2; shift 2 ;;
        --gpu) gpu=1; shift ;;
        --) shift; break ;;
        -*) echo "benchmark: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || { sed -n '2,12p' "$0" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/in.lammps-lj" <<'LAMMPS'
units lj
atom_style atomic
lattice fcc 0.8442
region box block 0 40 0 40 0 40
create_box 1 box
create_atoms 1 box
mass 1 1.0
velocity all create 1.44 87287 loop geom
pair_style lj/cut 2.5
pair_coeff 1 1 1.0 1.0 2.5
neighbor 0.3 bin
fix integrate all nve
run 200
LAMMPS
cat > "$work/in.lammps-pppm" <<'LAMMPS'
units real
atom_style charge
lattice sc 4.0
region box block 0 24 0 24 0 24
create_box 2 box
create_atoms 1 box
lattice sc 4.0 origin 0.5 0.5 0.5
create_atoms 2 box
mass * 22.99
set type 1 charge 1.0
set type 2 charge -1.0
pair_style lj/cut/coul/long 10.0
pair_coeff * * 0.1 3.0
kspace_style pppm 1.0e-5
velocity all create 300.0 87287 loop geom
timestep 0.5
fix integrate all nve
run 100
LAMMPS

# Ranks bound to cores (Open MPI's default for small counts made explicit), threads placed next to them.
launch() { # ranks command...
    n=$1; shift
    set -- -n "$n" --bind-to core --map-by "slot:PE=$threads" -x OMP_NUM_THREADS="$threads" \
        -x OMP_PLACES -x OMP_PROC_BIND "$@"
    [ -z "$hostfile" ] || set -- --hostfile "$hostfile" "$@"
    mpirun "$@"
}
command_for() { # case -> command line, run inside $work
    case "$1" in
        lammps-lj|lammps-pppm)
            if [ "$gpu" = 1 ]; then echo "lmp -k on g 1 t $threads -sf kk -in $work/in.$1 -log none -screen none"
            elif [ "$threads" -gt 1 ]; then echo "lmp -sf omp -pk omp $threads -in $work/in.$1 -log none -screen none"
            else echo "lmp -in $work/in.$1 -log none -screen none"; fi ;;
        pw:*) echo "pw.x -nk 1 -in ${1#pw:}" ;;
        cp2k:*) echo "cp2k.psmp -i ${1#cp2k:}" ;;
        *) echo "benchmark: unknown case $1" >&2; exit 2 ;;
    esac
}
now() { date +%s.%N; }

echo "case,ranks,threads,seconds,speedup,efficiency"
for case in "$@"; do
    cmd=$(command_for "$case")
    base=
    for n in $ranks; do
        start=$(now)
        # shellcheck disable=SC2086
        (cd "$work" && launch "$n" $cmd > "$work/out.$n" 2>&1) \
            || { tail -20 "$work/out.$n" >&2; echo "benchmark: $case failed on $n ranks" >&2; exit 1; }
        seconds=$(echo "$(now) $start" | awk '{ printf "%.2f", $1 - $2 }')
        [ -n "$base" ] || base="$n $seconds"
        echo "$case $n $threads $seconds $base" | awk '{
            speedup = $6 / $4; ideal = $2 / $5
            printf "%s,%d,%d,%.2f,%.2f,%.2f\n", $1, $2, $3, $4, speedup, speedup / ideal }'
    done
done
