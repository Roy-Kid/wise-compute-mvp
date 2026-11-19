# syntax=docker/dockerfile:1
ARG BASE_IMAGE
ARG CUDA_DEVEL_IMAGE

FROM ${CUDA_DEVEL_IMAGE} AS lammps
ARG APT_SNAPSHOT
ARG BUILD_JOBS=4
RUN printf 'APT::Snapshot "%s";\n' "${APT_SNAPSHOT:?}" > /etc/apt/apt.conf.d/50wise-snapshot \
    && rm -f /etc/apt/sources.list.d/cuda*.list \
    && apt-get update \
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
    && cmake --build /tmp/lammps/build --parallel "$BUILD_JOBS"

FROM ${BASE_IMAGE}
# Features install from the Ubuntu archive only. Dropping the NVIDIA apt source keeps every
# package source under the snapshot below; CUDA user-space libraries come from the base image.
ARG APT_SNAPSHOT
RUN printf 'APT::Snapshot "%s";\n' "${APT_SNAPSHOT:?}" > /etc/apt/apt.conf.d/50wise-snapshot \
    && rm -f /etc/apt/sources.list.d/cuda*.list
COPY --from=lammps /tmp/lammps/build/lmp /usr/local/bin/lmp-cuda
COPY --from=lammps /tmp/lammps/LICENSE /usr/local/share/licenses/lammps-cuda/LICENSE
