#!/bin/sh

lammps_cuda_build_jobs() (
    jobs=$(wise_build_jobs) || exit
    # NVCC uses more file handles per job than the host compiler.
    if [ "$jobs" -gt 12 ]; then jobs=12; fi
    printf '%s\n' "$jobs"
)

# Keep the compiler output live and capture it without hiding CMake's exit status.
lammps_cuda_build_once() (
    log=$3
    pipe=$log.pipe
    mkfifo "$pipe" || exit
    trap 'rm -f "$pipe"' EXIT
    tee "$log" < "$pipe" &
    reader=$!
    result=0
    cmake --build "$1" -j"$2" > "$pipe" 2>&1 || result=$?
    wait "$reader" || exit
    exit "$result"
)

lammps_cuda_build() (
    jobs=$2
    until lammps_cuda_build_once "$1" "$jobs" "$3"; do
        result=$?
        [ "$jobs" -gt 1 ] && grep -Fq 'Too many open files in system' "$3" || exit "$result"
        # Let the same build tree reuse objects from the successful jobs.
        jobs=$(( (jobs + 1) / 2 ))
        printf 'CUDA build: system file table exhausted, resuming with %s jobs\n' "$jobs" >&2
    done
)

# Linux reports allocated, unused and maximum file handles in that order.
lammps_cuda_file_table_available() (
    [ -r "$1" ] || exit 0
    # Some container runtimes expose this sysctl through a virtual file that requires a bulk read.
    counters=$(cat "$1") || exit
    read -r allocated unused maximum <<EOF
$counters
EOF
    [ -n "$maximum" ] || exit 0
    if [ "$((allocated - unused))" -ge "$maximum" ]; then
        printf 'CUDA build: the system file table is full (%s of %s allocated)\n' "$allocated" "$maximum" >&2
        exit 1
    fi
)

lammps_cuda_link_flags() {
    if [ ! -e "$CUDA_HOME/compat/libcuda.so.1" ]; then
        printf 'CUDA build: compatibility driver is missing at %s/compat/libcuda.so.1\n' "$CUDA_HOME" >&2
        return 1
    fi
    printf '%s\n' "-Wl,-rpath-link,$CUDA_HOME/compat"
}

# Reproduce the executable -> shared library -> libcuda link before compiling LAMMPS.
lammps_cuda_link_probe() (
    compiler=$1
    linker_flags=$2
    probe=$(mktemp -d) || exit
    trap 'rm -rf "$probe"' EXIT
    cd "$probe" || exit
    printf '#include <cuda.h>\nextern "C" int driver_probe() { return cuInit(0); }\n' > driver.cpp
    printf 'extern "C" int driver_probe();\nint main(int n, char **) { return n == 1 ? 0 : driver_probe(); }\n' > main.cpp
    g++ -shared -fPIC -I"$CUDA_HOME/include" driver.cpp -L"$CUDA_HOME/lib64/stubs" -lcuda -o libdriver_probe.so || exit
    "$compiler" main.cpp -L. -ldriver_probe "$linker_flags" -o main || exit
    LD_LIBRARY_PATH="$probe:${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$CUDA_HOME/compat" ./main
)
