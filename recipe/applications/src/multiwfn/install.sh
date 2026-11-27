#!/bin/sh
set -eu
wise_id=multiwfn
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

release=Multiwfn_2026.11.26_bin_Linux_noGUI
home=$WISE_PREFIX/share/multiwfn
wise_apt ca-certificates curl unzip
wise_workdir
# The Multiwfn site serves no HTTPS; the checksum fixes the content.
wise_retry curl --fail --location --silent --show-error --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
    "http://sobereva.com/multiwfn/misc/$release.zip" -o "$WISE_WORK/$release.zip"
echo "41bbca92de4923a3c005b6430a249182b5768d70614b49e317052d55ec3aa493  $WISE_WORK/$release.zip" \
    | sha256sum --check --quiet || wise_fail "checksum mismatch for $release.zip"
unzip -q "$WISE_WORK/$release.zip" -d "$WISE_WORK"
rm -rf "$home"
mv "$WISE_WORK/$release" "$home"
chmod -R a+rX,go-w "$home"
chmod 755 "$home/Multiwfn_noGUI"

# Section 2.1.2 of the manual: an unlimited stack, a large OpenMP stack and the folder of settings.ini.
cat > "$WISE_PREFIX/bin/Multiwfn" <<COMMAND
#!/bin/sh
ulimit -s unlimited 2>/dev/null || true
export OMP_STACKSIZE="\${OMP_STACKSIZE:-200M}" Multiwfnpath="\${Multiwfnpath:-$home}"
exec "$home/Multiwfn_noGUI" "\$@"
COMMAND
chmod 755 "$WISE_PREFIX/bin/Multiwfn"
ln -sf Multiwfn "$WISE_PREFIX/bin/Multiwfn_noGUI"

wise_linked "$home/Multiwfn_noGUI"
test -s "$home/settings.ini" && test -s "$home/LICENSE.txt" || wise_fail "the Multiwfn package is incomplete"
wise_done
