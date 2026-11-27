#!/bin/sh
set -eu
umask 077
[ "$(id -u)" = 1000 ] && [ "$(id -g)" = 1000 ] || { echo 'Compute requires UID/GID 1000' >&2; exit 78; }
[ -r /run/wise-compute/authorized_keys ] && [ -s /run/wise-compute/authorized_keys ] || { echo 'Missing authorized public key' >&2; exit 78; }
# Reject options and multiline keys: the control plane supplies one request key.
[ "$(awk 'END { print NR }' /run/wise-compute/authorized_keys)" = 1 ] || exit 78
awk 'NF >= 2 && $1 == "ssh-ed25519" { valid=1 } END { exit !valid }' /run/wise-compute/authorized_keys || exit 78
[ -d /work ] && [ -w /work ] && [ -d /run/wise-compute-host ] && [ -w /run/wise-compute-host ] || { echo 'Missing writable compute volumes' >&2; exit 78; }
# OpenMPI needs writable temporary storage even for singleton calculations.
# The root filesystem, including /tmp, can be read-only on VCI.
mkdir -p /work/.tmp
chmod 700 /work/.tmp
mkdir -p /run/wise-compute-host/keys
chmod 700 /run/wise-compute-host/keys
key=/run/wise-compute-host/keys/ssh_host_ed25519_key
if [ ! -e "$key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C wise-compute-host -f "$key"
fi
[ -f "$key" ] && [ ! -L "$key" ] || exit 78
chmod 600 "$key"
# The public identity is attested by the control plane against this exact Pod UID.
public=$(ssh-keygen -y -f "$key" | awk '{ print $1 " " $2 }')
printf 'WISE_COMPUTE_HOST_KEY=%s\n' "$public"
cd /work
exec /usr/sbin/sshd -D -e -f /etc/ssh/wise_compute_sshd_config
