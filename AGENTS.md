# Instructions for AI agents

How an AI coding agent should install, start and check this deployment for a user.
`README.md` explains why each setting exists. This file is the procedure.

## Rules

- **Do not weaken the isolation.** Never give the `halogen` container a network with
  egress, remove `Internal=true`, set `HALOGEN_DOWNLOAD`, publish the port on anything
  other than `127.0.0.1` (unless the user asks for LAN access), add `--privileged`,
  `label=disable`, `container_use_devices=on`, `keep-groups`, or change `UserNS=nomap`.
  If something fails, report it instead of loosening these.
- **Do not change the image digests** unless the user asks for an upgrade (see
  "Upgrading" in `README.md`).
- **Do not use `:z`/`:Z` on the models mount.** It would relabel ~120 GB at every start.
- **Root steps are the user's.** `sudo ./host/halogen-host-setup.sh` needs the user's
  password and must run in a host terminal, not in a toolbox or other container. Ask
  the user to run it, and do not run it yourself unless they give you the go-ahead and
  you are on the host (`[ ! -e /run/.containerenv ]`).
- **The model weights cannot be downloaded by you.** `qwen38-flash-next-v2.hgn` and its
  tokenizer come from the Halogen provider. If they are missing, stop and ask the user.
- Run every command from the repository root.

## 1. Check the machine

Run these and stop on the first failure, telling the user what is missing:

```bash
[ ! -e /run/.containerenv ] || echo "inside a container: run on the host"
podman --version                                   # needs >= 5
test -x /usr/libexec/podman/quadlet && echo quadlet ok
ls -l /dev/kfd /dev/dri/renderD* /dev/accel/accel0  # all three must exist and be crw-rw-rw-
id -nG | tr ' ' '\n' | grep -E '^(render|video)$'  # both groups
free -g                                            # ~104 GB RAM for the container
df -h ~                                            # ~135 GB for the models
getenforce                                         # Enforcing is expected and fine
```

- If the render node is not `renderD128`, change `AddDevice=/dev/dri/renderD128` in
  `halogen.container` to the existing one.
- If `/dev/accel/accel0` is missing, the machine has no usable Ryzen AI NPU (or the
  `amdxdna` driver/IOMMU is off). This setup expects it: tell the user rather than
  editing the units to run without it.
- If the user lacks `render` or `video`, they must run
  `sudo usermod -aG render,video $USER` and log in again.

## 2. Check the model weights

```bash
ls -la ~/halogen-models/qwen38-flash-next-v2.hgn ~/halogen-models/tokenizer/
```

If either is missing, stop and ask the user to place them there. Then:

```bash
chmod -R a+rX ~/halogen-models
```

## 3. Fetch XRT and the NPU models

Both scripts use throwaway containers with network; they are safe to re-run and skip
files that are already correct.

```bash
./halogen-fetch-xrt.sh     # -> ~/halogen-xrt/lib (three libxrt_*.so.2 files)
./halogen-fetch-npu.sh     # -> ~/halogen-models/npu, ~15 GB, every file sha256-checked
```

A sha256 mismatch from `halogen-fetch-npu.sh` is a hard failure: report it, do not
skip the check.

## 4. Host setup (root, once)

Ask the user to run, in a host terminal:

```bash
sudo ./host/halogen-host-setup.sh
```

Then confirm it worked (no root needed):

```bash
ls -Z /dev/accel/accel0 | grep dri_device_t
/usr/local/sbin/halogen-fabric-clock status          # must say "held"
prlimit --pid "$(systemctl show -p MainPID --value user@$(id -u).service)" --memlock
                                                     # HARD must be unlimited
```

## 5. Install and start

```bash
./install.sh
```

It repeats the checks from steps 3 and 4 and exits with a message naming the step to
redo if any fails. On success it starts `halogen.service` (and the proxy).

Loading takes several minutes (the unit allows up to 15). Wait for the API instead of
assuming it is up:

```bash
for i in $(seq 90); do curl -sf localhost:8731/v1/models >/dev/null && break; sleep 10; done
curl -s localhost:8731/v1/models
```

While waiting, or if it never comes up:

```bash
systemctl --user status halogen halogen-proxy --no-pager
journalctl --user -u halogen -n 100 --no-pager
```

Match errors against "Known issues" in `README.md`. To keep it running without a
login session the user can run `loginctl enable-linger $USER`; ask before doing it.

## 6. Verify

Run the API, NPU, no-egress and port checks under "6. Verify" in `README.md`.
Report each result. The two egress commands **must fail**; if either succeeds, the
isolation is broken: stop the service (`systemctl --user stop halogen`) and tell the
user. `ss -tlnp | grep 8731` must show only `127.0.0.1:8731`.

## Using the server

- OpenAI-compatible: `http://127.0.0.1:8731/v1/chat/completions`, `/v1/models`,
  `/v1/embeddings`, `/v1/rerank`, `/v1/audio/transcriptions`, `/v1/audio/speech`.
- Anthropic-compatible: `http://127.0.0.1:8731/v1/messages`.
- No API key is needed. The `model` field selects an NPU model (table in `README.md`);
  any other value goes to Qwen3.8-Flash-Next.

## Day-to-day commands

```bash
systemctl --user restart halogen      # after editing a unit: ./install.sh instead
systemctl --user stop halogen halogen-proxy
journalctl --user -u halogen -f
```
