#!/bin/bash
# Installs the (user) quadlet units and starts halogen.
# First: ./halogen-fetch-xrt.sh, ./halogen-fetch-npu.sh and sudo ./host/halogen-host-setup.sh
set -euo pipefail
cd "$(dirname "$0")"
Q="$HOME/.config/containers/systemd"

# Prerequisite checks: without these the server refuses to start with the NPU
fail=0
for f in libxrt_coreutil.so.2 libxrt_core.so.2 libxrt_driver_xdna.so.2; do
  [ -f "$HOME/halogen-xrt/lib/$f" ] || { echo "missing ~/halogen-xrt/lib/$f: run ./halogen-fetch-xrt.sh" >&2; fail=1; }
done
[ -d "$HOME/halogen-models/npu" ] || { echo "NPU models missing: run ./halogen-fetch-npu.sh" >&2; fail=1; }
ls -Z /dev/accel/accel0 | grep -q dri_device_t || { echo "/dev/accel/accel0 lacks the dri_device_t label: sudo ./host/halogen-host-setup.sh" >&2; fail=1; }
/usr/local/sbin/halogen-fabric-clock status 2>/dev/null | grep -q held || { echo "fabric clock not held: sudo ./host/halogen-host-setup.sh" >&2; fail=1; }
P=$(systemctl show -p MainPID --value "user@$(id -u).service")
prlimit --pid "$P" --memlock --noheadings -o HARD | grep -q unlimited || { echo "memlock of user@$(id -u) is limited: sudo ./host/halogen-host-setup.sh" >&2; fail=1; }
[ "$fail" = 0 ] || exit 1

# SELinux: container_t cannot read user_home_t (and logs no AVC). Shared label, once;
# ':z' on Volume= would relabel ~120 GB at every start.
ls -Zd "$HOME/halogen-models" | grep -q container_file_t || chcon -R -t container_file_t "$HOME/halogen-models"

# If it was already installed, stop it before replacing the units
systemctl --user stop halogen.service 2>/dev/null || true
mkdir -p "$Q"

cp halogen-int.network halogen-ext.network \
   halogen-proxy.container halogen.container "$Q/"
systemctl --user daemon-reload
/usr/libexec/podman/quadlet -dryrun -user > /dev/null

systemctl --user start halogen.service
echo "starting; follow the log with: journalctl --user -u halogen -f"
