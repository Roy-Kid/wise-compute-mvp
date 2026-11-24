# syntax=docker/dockerfile:1
# Base tier, CPU: Ubuntu 24.04. Every later apt-get resolves against one archive snapshot.
ARG BASE_IMAGE=harbor.will/docker.io/library/ubuntu@sha256:67efaecc0031a612cf7bb3c863407018dbbef0a971f62032b77aa542ac8ac0d2
FROM ${BASE_IMAGE}
ARG APT_SNAPSHOT=20261101T000000Z
RUN . /etc/os-release && test "$VERSION_ID" = 24.04 \
    && printf 'APT::Snapshot "%s";\n' "$APT_SNAPSHOT" > /etc/apt/apt.conf.d/50wise-snapshot \
    && test ! -e /usr/local/cuda && ! command -v nvcc
