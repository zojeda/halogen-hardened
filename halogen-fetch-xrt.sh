#!/bin/bash
# Extracts XRT 2.25 + the NPU plugin (libxrt2, libxrt-npu2) from Debian trixie-backports into ~/halogen-xrt/lib.
# The halogen image is Debian 13, so these libraries match its glibc/libstdc++.
# Fedora does not package XRT; this way nothing is installed on the host (rpm-ostree untouched).
# Runs in a throwaway container with network; the server never has network.
set -euo pipefail

DEBIAN=docker.io/library/debian@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad  # trixie-slim
OUT="${HALOGEN_XRT_DIR:-$HOME/halogen-xrt}"

mkdir -p "$OUT"
podman run --rm --pull=missing \
  --cap-drop=all --cap-add=CHOWN,DAC_OVERRIDE,FOWNER,SETUID,SETGID \
  --security-opt no-new-privileges --pids-limit 256 --memory 1g \
  -v "$OUT":/out:z \
  "$DEBIAN" bash -euo pipefail -c '
    echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/bpo.list
    apt-get -qq -o APT::Sandbox::User=root update
    cd /tmp
    apt-get -qq -o APT::Sandbox::User=root download -t trixie-backports libxrt2 libxrt-npu2
    rm -rf /out/root /out/lib && mkdir -p /out/root /out/lib
    for d in ./*.deb; do dpkg-deb -x "$d" /out/root; done
    sha256sum ./*.deb > /out/debs.sha256
    L=/out/root/usr/lib/x86_64-linux-gnu
    # Real files (not symlinks): the mount must not carry links pointing outside the container
    for f in libxrt_coreutil.so.2 libxrt_core.so.2 libxrt_driver_xdna.so.2; do
      cp -L "$L/$f" /out/lib/$f
    done
    readlink "$L/libxrt_coreutil.so.2" > /out/VERSION
    chmod -R a+rX /out
  '
echo "XRT en $OUT/lib ($(cat "$OUT/VERSION")):"
ls -l "$OUT/lib"
