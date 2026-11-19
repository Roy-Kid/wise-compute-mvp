# syntax=docker/dockerfile:1
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Every later apt-get, including those run by Features, resolves against one Ubuntu archive snapshot.
ARG APT_SNAPSHOT
RUN printf 'APT::Snapshot "%s";\n' "${APT_SNAPSHOT:?}" > /etc/apt/apt.conf.d/50wise-snapshot
