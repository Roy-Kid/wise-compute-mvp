#!/bin/sh
# Starts a compute image the way the platform does and runs the materials self-test through its SSH
# entrance: user 1000:1000, read-only root, no capabilities, one request key, writable /work and
# /run/wise-compute-host. It then fetches the results over SCP and SFTP.
#
#   sh check.sh IMAGE [materials-selftest options and tests]
#
# Results go to COMPUTE_CHECK_OUT (default ./compute-check). Uses every GPU when the host has nvidia-smi.
# CONTAINER_ENGINE selects docker (default) or podman. Needs ssh, scp, sftp and ssh-keygen on this machine.
set -eu
[ $# -ge 1 ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
image=$1; shift
here=$(cd "$(dirname "$0")" && pwd)
engine=${CONTAINER_ENGINE:-docker}
out=${COMPUTE_CHECK_OUT:-$PWD/compute-check}
mkdir -p "$out"
out=$(cd "$out" && pwd)
name=wise-compute-check-$$
state=$(mktemp -d)
cleanup() {
    "$engine" rm -f "$name" > /dev/null 2>&1 || true
    "$engine" volume rm -f "$name-key" "$name-host" "$name-work" > /dev/null 2>&1 || true
    rm -rf "$state"
}
trap cleanup EXIT
fail() { echo "FAILED: $*" >&2; "$engine" logs "$name" 2>&1 | tail -n 20 >&2 || true; exit 1; }
step() { echo "[ ok ] $*"; }

# The image itself: no host key from the build, and it runs as compute by default.
"$engine" run --rm --entrypoint sh "$image" -c '! ls /etc/ssh/ssh_host_* > /dev/null 2>&1 && [ "$(id -un):$(id -gn):$(id -u):$(id -g)" = compute:compute:1000:1000 ] && [ "$HOME:$PWD" = /work:/work ]' \
    || fail "the image holds a host key, or its default user is not compute 1000:1000 in /work"
step "image has no host key; default user compute 1000:1000, HOME and working directory /work"

# One request key, read-only and owned by root as the control plane provides it. A new volume takes the
# owner of the image directory it covers, which is how /work and /run/wise-compute-host become writable.
ssh-keygen -q -t ed25519 -N '' -C compute-check -f "$state/key"
ssh-keygen -q -t ed25519 -N '' -C compute-check-other -f "$state/other"
"$engine" run --rm -i --user 0:0 --entrypoint sh -v "$name-key:/run/wise-compute" "$image" \
    -c 'cat > /run/wise-compute/authorized_keys && chmod 644 /run/wise-compute/authorized_keys' < "$state/key.pub"
gpus=
if command -v nvidia-smi > /dev/null && nvidia-smi -L > /dev/null 2>&1; then gpus="--gpus all"; fi
"$engine" run -d --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges --shm-size=2g $gpus \
    -v "$name-key:/run/wise-compute:ro" -v "$name-host:/run/wise-compute-host" -v "$name-work:/work" \
    -p 127.0.0.1::2222 "$image" > /dev/null

# The entrance announces the instance's host key; trust exactly that key.
tries=0
until line=$("$engine" logs "$name" 2> /dev/null | grep '^WISE_COMPUTE_HOST_KEY=ssh-ed25519 '); do
    tries=$((tries + 1)); [ "$tries" -le 30 ] || fail "the entrance did not print WISE_COMPUTE_HOST_KEY"
    [ "$("$engine" inspect -f '{{.State.Running}}' "$name")" = true ] || fail "the container stopped"
    sleep 1
done
port=$("$engine" port "$name" 2222/tcp | sed -n '1s/.*://p')
echo "[127.0.0.1]:$port ${line#WISE_COMPUTE_HOST_KEY=}" > "$state/known_hosts"
options="-o UserKnownHostsFile=$state/known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=20 -o LogLevel=ERROR"
remote() { ssh $options -i "$state/key" -p "$port" compute@127.0.0.1 "$@"; }
tries=0
until remote true 2> /dev/null; do tries=$((tries + 1)); [ "$tries" -le 20 ] || fail "no SSH session with the request key"; sleep 1; done
step "entrance printed its host key; SSH session with the request key on port 2222"

[ "$("$engine" exec "$name" sh -c 'for p in /proc/[0-9]*; do awk "/^Uid:/ { print \$2 }" "$p/status"; done | sort -u')" = 1000 ] \
    || fail "a process of the container does not run as UID 1000"
[ "$(remote 'echo "$(id -un):$(id -u):$(id -g):$HOME:$PWD:$TMPDIR"')" = compute:1000:1000:/work:/work:/work/.tmp ] \
    || fail "the session is not compute 1000:1000 in /work"
step "every process runs as UID 1000; the session is compute in /work"

# A command over SSH has the environment of a command in the container.
skip='^(HOSTNAME|PWD|OLDPWD|SHLVL|_|NVIDIA_[A-Z_]*|MELLANOX_VISIBLE_DEVICES|CUDA_VERSION)='
"$engine" exec "$name" env | grep -Ev "$skip" | sort > "$state/container.env"
remote env | sort > "$out/session.env"
missing=$(comm -23 "$state/container.env" "$out/session.env")
[ -z "$missing" ] || fail "the SSH session lacks or changes: $missing"
step "the SSH session has all $(wc -l < "$state/container.env") environment variables of the container"

ssh $options -i "$state/key" -p "$port" root@127.0.0.1 true 2> /dev/null && fail "root may log in"
ssh $options -i "$state/other" -p "$port" compute@127.0.0.1 true 2> /dev/null && fail "a key that was not requested may log in"
ssh $options -o BatchMode=no -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
    -o NumberOfPasswordPrompts=0 -p "$port" compute@127.0.0.1 true 2> /dev/null && fail "password login is offered"
step "root, another key and passwords are refused"

scp -q -r $options -i "$state/key" -P "$port" "$here/../selftest" compute@127.0.0.1:/work/selftest || fail "SCP upload"
status=0
remote sh /work/selftest/materials-selftest --logs /work/selftest-logs --json /work/selftest-logs/result.json "$@" || status=$?

rm -rf "$out/selftest-logs" "$out/result.json"
scp -q -r $options -i "$state/key" -P "$port" compute@127.0.0.1:/work/selftest-logs "$out/selftest-logs" || fail "SCP download"
echo "get /work/selftest-logs/result.json $out/result.json" | sftp -q -b - $options -i "$state/key" -P "$port" compute@127.0.0.1 > /dev/null \
    || fail "SFTP download"
cmp -s "$out/result.json" "$out/selftest-logs/result.json" || fail "SFTP and SCP returned different results"
step "results fetched over SCP and SFTP: $out"
[ "$status" = 0 ] || fail "the self-test over SSH ended with status $status"
echo "compute check passed"
