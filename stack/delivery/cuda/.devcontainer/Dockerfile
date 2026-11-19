# syntax=docker/dockerfile:1
ARG CUDA_RUNTIME
FROM docker.io/nvidia/cuda:12.9.1-devel-ubuntu24.04@sha256:e542739fcaa4f45da5add8c4cf5769783a61628b2518304a5bbe4ace468b8c8f AS lammps
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake g++ \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:2873c1a35b985fdbb61238d24995818b6bb359251b6b054e9c4291b7783d59ab \
    https://codeload.github.com/lammps/lammps/tar.gz/611ca3b7f8525ba802373b04f9e3d632d515f7e3 \
    /tmp/lammps.tar.gz
RUN mkdir /tmp/lammps \
    && tar -xzf /tmp/lammps.tar.gz --strip-components=1 -C /tmp/lammps \
    && cmake -S /tmp/lammps/cmake -B /tmp/lammps/build \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_MPI=OFF -DBUILD_OMP=OFF \
        -DBUILD_SHARED_LIBS=OFF -DPKG_GPU=ON -DGPU_API=cuda -DGPU_PREC=double \
        -DCUDA_BUILD_MULTIARCH=ON \
    && cmake --build /tmp/lammps/build --parallel 2

FROM ${CUDA_RUNTIME}
COPY --from=lammps /tmp/lammps/build/lmp /usr/local/bin/lmp-cuda
COPY --from=lammps /tmp/lammps/LICENSE /usr/local/share/licenses/lammps-cuda/LICENSE
