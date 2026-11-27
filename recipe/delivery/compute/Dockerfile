# The platform's managed SSH entrance on a finished materials image, the same for CPU and CUDA.
# Context: this directory. BASE_IMAGE is the verified image of recipe/delivery/cpu or cuda;
# `wisehub image extend` passes it.
# No "syntax" line: the builder's own Dockerfile frontend is enough, and the build then needs no Docker Hub.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
# The image's ENV, here and in every SSH session; before the build arguments below join the environment.
ENV MKL_NUM_THREADS=1 MPLBACKEND=Agg
RUN --mount=type=bind,source=session-env.py,target=/tmp/session-env.py \
    --mount=type=bind,source=sshd_config,target=/tmp/sshd_config \
    python3 /tmp/session-env.py /tmp/sshd_config /etc/ssh/wise_compute_sshd_config
# The version the Ubuntu 24.04 snapshot of both base images (APT_SNAPSHOT) offers.
ARG OPENSSH_VERSION=1:9.6p1-3ubuntu13.20
RUN set -eu; \
    test "$(dpkg --print-architecture)" = amd64; \
    apt-get -o APT::Update::Error-Mode=any update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "openssh-server=${OPENSSH_VERSION}" "openssh-client=${OPENSSH_VERSION}" python3 ca-certificates coreutils util-linux; \
    # No host key of the build machine may reach an instance; the entrance creates one per instance.
    rm -f /etc/ssh/ssh_host_*; rm -rf /var/lib/apt/lists/*; \
    # Ubuntu's own account holds 1000:1000; it becomes compute instead of a second account with that number.
    # "*" is no password, yet not a locked account, which sshd would refuse without PAM.
    if [ "$(getent passwd 1000 | cut -d: -f1)" = ubuntu ]; then \
        usermod --login compute --home /work --shell /bin/bash --groups "" --comment "WiSE compute" --password '*' ubuntu; \
        groupmod --new-name compute ubuntu; \
        sed -i '/^ubuntu:/d' /etc/subuid /etc/subgid; rm -rf /home/ubuntu; \
    fi; \
    test "$(getent passwd 1000)" = "compute:x:1000:1000:WiSE compute:/work:/bin/bash"; \
    test "$(getent group 1000)" = "compute:x:1000:"; \
    test "$(awk -F: '$3 == 1000' /etc/passwd | wc -l)" = 1; test "$(id -Gn compute)" = compute; \
    # Nothing of the software may belong to the account that runs the jobs. An image built before the
    # nodejs Feature unpacked without the archive's owner has /usr/local/bin and more under 1000.
    find / -xdev \( -user 1000 -o -group 1000 \) -exec chown -h root:root {} +; \
    test -z "$(find / -xdev \( -user 1000 -o -group 1000 \) -print -quit)"; \
    mkdir -p /run/sshd /run/wise-compute /run/wise-compute-host /work; \
    chown 1000:1000 /run/wise-compute-host /work; \
    # sshd accepts the configuration and takes the whole session environment from it.
    /usr/sbin/sshd -G -f /etc/ssh/wise_compute_sshd_config > /tmp/sshd.txt; \
    grep -qx 'setenv HOME=/work' /tmp/sshd.txt; grep -q "^setenv PATH=/opt/venv/bin:" /tmp/sshd.txt; \
    grep -qx 'permitrootlogin no' /tmp/sshd.txt; grep -qx 'passwordauthentication no' /tmp/sshd.txt; \
    rm /tmp/sshd.txt; \
    dpkg-query -W > /opt/wise-compute-system-packages.txt
COPY --chmod=755 entrypoint.sh /usr/local/bin/wise-compute-entrypoint
ARG BASE_IMAGE
ARG COMPUTE_TARGET
ARG VERSION
RUN case "$COMPUTE_TARGET" in aliyun-acs|aliyun-ack-gpu) ;; *) echo "COMPUTE_TARGET is aliyun-acs or aliyun-ack-gpu" >&2; exit 78 ;; esac
LABEL io.wise.compute.target="${COMPUTE_TARGET}" io.wise.compute.ssh.protocol="v1" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" org.opencontainers.image.version="${VERSION}"
ENV HOME=/work TMPDIR=/work/.tmp
USER 1000:1000
WORKDIR /work
EXPOSE 2222
# Replaces bash on CPU and the NVIDIA HPC SDK banner script on CUDA, which sets up nothing: the CUDA
# environment is the image's ENV. The entrance takes no command.
ENTRYPOINT ["/usr/local/bin/wise-compute-entrypoint"]
CMD []
