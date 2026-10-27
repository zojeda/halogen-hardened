#!/bin/bash
# Host steps that need root, once. Usage: sudo ./host/halogen-host-setup.sh
#  1. SELinux: /dev/accel/accel0 is born device_t and container_t cannot open it.
#     It is labelled dri_device_t (same as /dev/dri/renderD128), instead of
#     label=disable or container_use_devices=on, which open up much more.
#  2. GPU fabric clock held at its top level: on Strix Halo, GPU + NPU at once can
#     hang the machine while that clock changes. Official halogen-flash-server unit
#     (deploy/host/), runs at boot and after every resume. Costs ~1 W.
#  3. Unlimited memlock for the user's systemd --user (halogen.service runs there, and a
#     rootless container cannot exceed that limit): the NPU pins ~12 GiB.
#     Only for that user, not a global limits.conf.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ ! -e /run/.containerenv ] || { echo "you are inside a toolbox: run it in a host terminal" >&2; exit 1; }
cd "$(dirname "$0")"

# Only the character node; the /dev/accel directory cannot carry dri_device_t
semanage fcontext -l -C | grep -qF '/dev/accel(/.*)?' && semanage fcontext -d '/dev/accel(/.*)?'
if ! semanage fcontext -l -C | grep -qF '/dev/accel/accel[0-9]+'; then
  semanage fcontext -a -f c -t dri_device_t '/dev/accel/accel[0-9]+'
fi
restorecon -v /dev/accel/accel*
ls -lZ /dev/accel/accel0

install -m 755 halogen-fabric-clock /usr/local/sbin/
install -m 644 halogen-fabric-clock.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now halogen-fabric-clock.service
/usr/local/sbin/halogen-fabric-clock status

U="${SUDO_UID:-${PKEXEC_UID:-}}"
[ -n "$U" ] || { echo "cannot tell the user: run with sudo or pkexec" >&2; exit 1; }
mkdir -p "/etc/systemd/system/user@$U.service.d"
printf '[Service]\nLimitMEMLOCK=infinity\n' > "/etc/systemd/system/user@$U.service.d/halogen-memlock.conf"
systemctl daemon-reload
# Apply it now to the running systemd --user (otherwise it takes effect at the next login/boot)
P=$(systemctl show -p MainPID --value "user@$U.service")
[ "${P:-0}" -gt 0 ] && prlimit --pid "$P" --memlock=unlimited:unlimited
echo "memlock of user@$U: $(prlimit --pid "$P" --memlock --noheadings -o SOFT,HARD)"
