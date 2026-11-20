# syntax=docker/dockerfile:1
# Base tier, CPU: Ubuntu 24.04. Every later apt-get resolves against one archive snapshot.
ARG BASE_IMAGE=public.ecr.aws/docker/library/ubuntu@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
FROM ${BASE_IMAGE}
ARG APT_SNAPSHOT=20261101T000000Z
RUN . /etc/os-release && test "$VERSION_ID" = 24.04 \
    && printf 'APT::Snapshot "%s";\n' "$APT_SNAPSHOT" > /etc/apt/apt.conf.d/50wise-snapshot \
    && test ! -e /usr/local/cuda && ! command -v nvcc
