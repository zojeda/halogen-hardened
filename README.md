# Isolated Halogen Flash Server (podman + quadlet)

Runs the Halogen inference server (proprietary `flash_serve` binary) in rootless
podman containers with **no network access**: it cannot reach the internet, the
LAN or any VPN. The only way in is a `socat` proxy that publishes the API on
`127.0.0.1:8731`.

```
 client ──► 127.0.0.1:8731 ──► halogen-proxy (socat) ──► halogen
                                networks: ext + int        network: int (Internal=true, no egress)
```

The server is the `halogen` unit: Qwen3.8-Flash-Next on the
GPU, `halogen-flash-server` 0.18.16 pinned by digest. It also serves small models on the Ryzen AI NPU,
behind the same port; a request picks one by its `model`
([upstream docs](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md)):

| `model`                       | Use            | Endpoint                                              |
|-------------------------------|----------------|-------------------------------------------------------|
| `decider-0.8b`                | decisions      | `/v1/chat/completions` (`response_format` json_schema), `/v1/systemone` |
| `qwen3-embedding-0.6b`        | embeddings     | `/v1/embeddings`                                      |
| `qwen3-reranker-0.6b`         | reranking      | `/v1/rerank`                                          |
| `qwen3-asr-1.7b`              | speech to text | `/v1/audio/transcriptions` (WAV, up to 20 min)        |
| `qwen3-tts-1.7b-customvoice`  | text to speech | `/v1/audio/speech` (WAV/PCM, 9 voices)                |

Any other `model` goes to Qwen3.8-Flash-Next, as before.

<details>
<summary><b>Installing with an AI agent (Claude Code, Codex, Cursor, …)</b></summary>

Paste this prompt into your coding agent:

```text
Install and start the isolated Halogen Flash Server from
https://github.com/zojeda/halogen-hardened on this machine.
Clone the repo, then follow AGENTS.md step by step:
https://raw.githubusercontent.com/zojeda/halogen-hardened/main/AGENTS.md
Do not weaken any isolation setting to get past an error; report it instead.
Ask me before anything that needs sudo, and stop if the model weights are missing.
```

What the agent will do (full procedure in [`AGENTS.md`](AGENTS.md); Claude Code loads
it automatically through `CLAUDE.md`):

1. Check podman, quadlet, the GPU/NPU device nodes, groups, RAM and disk.
2. Check that the model weights are in `~/halogen-models` (it cannot download them).
3. Run `./halogen-fetch-xrt.sh` and `./halogen-fetch-npu.sh`.
4. Ask you to run `sudo ./host/halogen-host-setup.sh` in a host terminal, then confirm it.
5. Run `./install.sh` and wait for the API on `127.0.0.1:8731`.
6. Run the checks in "6. Verify", including that the server has no egress.

</details>

## Isolation measures

- `Internal=true` network: no egress anywhere; only the proxy talks to it.
- API published on localhost only.
- Images pinned by digest (a re-pushed tag does not affect you).
- Read-only root filesystem, `/tmp` on tmpfs, models mounted `:ro`.
- `DropCapability=ALL`, `NoNewPrivileges=true`, memory and PID limits.
- GPU: only `/dev/kfd` and the render node (`renderD128`), not the display nodes.
  These device nodes must be mode `0666` on the host (`ls -l /dev/kfd /dev/dri/renderD128
  /dev/accel/accel0`), since `UserNS=nomap` rules out `--group-add keep-groups`.
- `UserNS=nomap`: your UID is not mapped; container root is your first subUID (from
  `/etc/subuid`), so an escape can neither read your home nor your session's IPC /
  `/dev/shm` objects. (`UserNS=auto` would be better, but it fails when other
  containers, such as toolbox ones, already hold the whole subUID range.)
  Models and XRT must be world-readable (`chmod -R a+rX`).
- Exception: `--ipc=host`. With its own IPC namespace `flash_serve` 0.18.16
  segfaults while preparing the weights (tested: `ShmSize` 16g and 100g, an exec
  `/dev/shm`, raised `kernel.shm*` sysctls). With `UserNS=nomap` it cannot reach
  your session's private IPC objects.
- NPU: only `/dev/accel/accel0`, relabelled `dri_device_t` (same as the render node)
  instead of `label=disable` or `container_use_devices=on`.
- NPU models and XRT are fetched by separate throwaway containers with network;
  the server never gets `HALOGEN_DOWNLOAD` and opens no outbound connections.
  Every NPU file is checked against the sha256 recorded in the pinned image, by the
  fetch script and again by the server at every start.
- Rootless: if something escapes the container it is not root (nor your user).

## Requirements

- Linux with podman ≥ 5 (includes quadlet) and systemd. Tested on Fedora 44 (Atomic).
- AMD GPU with ROCm kernel support: `/dev/kfd` and `/dev/dri/renderD*` must exist.
- Your user in the `render` and `video` groups:
  ```bash
  id -nG | tr ' ' '\n' | grep -E '^(render|video)$'
  # if one is missing: sudo usermod -aG render,video $USER  (then log in again)
  ```
- Memory: ~75 GB in use with Qwen (73 GB peak observed), plus up to ~15 GB pinned
  by the NPU models (the container limit is set to 104 GB). To make room, the KV
  pool is halved (`HALOGEN_KV_POOL_POSITIONS=262144`, ~7.4 GiB instead of ~14.9 GiB):
  each request can still use 262144 tokens, but that is now the total shared by
  concurrent requests.
- Disk space: ~120 GB for the models, ~15 GB more for the NPU models.
- For the NPU: Strix Halo with the `amdxdna` driver (in the Fedora kernel), its
  firmware (`linux-firmware`) and the IOMMU on (`ls /dev/accel/accel0`).

## 1. Models

The weights are not included in the image. Get them from the Halogen provider and
place them in `~/halogen-models` with this layout:

```
~/halogen-models/
├── qwen38-flash-next-v2.hgn   # Qwen model (for halogen)
├── tokenizer/                 # Qwen tokenizer
└── npu/                       # NPU models (halogen-fetch-npu.sh)
```

They are mounted read-only, so they must be readable by your user:
```bash
chmod -R a+rX ~/halogen-models
```

With SELinux enforcing (Fedora), containers cannot read `user_home_t` files and the
denial is not logged. `install.sh` labels the directory once:
```bash
chcon -R -t container_file_t ~/halogen-models
```
(`:z` on the mount would relabel ~120 GB at every start.)

## 2. Check the render node

The `.container` files use `/dev/dri/renderD128`. If your GPU has a different number:
```bash
ls /dev/dri/
```
and adjust `AddDevice=/dev/dri/renderD...` in `halogen.container`.

## 2b. NPU: XRT, models and host setup

Fedora does not package XRT, so `halogen-fetch-xrt.sh` extracts XRT 2.25 and its NPU
plugin from Debian trixie-backports (the image is Debian 13, so they match its C
runtime) into `~/halogen-xrt/lib`. Nothing is installed on the host:
```bash
./halogen-fetch-xrt.sh
```
(`HALOGEN_XRT_DIR` changes the output directory, but `halogen.container` mounts
`%h/halogen-xrt/lib`, so adjust its `Volume=` lines too.)

Download the NPU models named in `HALOGEN_NPU_MODELS` (in `halogen.container`) into
`~/halogen-models/npu`, from the repo and commit the pinned image records:
```bash
./halogen-fetch-npu.sh                      # models from HALOGEN_NPU_MODELS
./halogen-fetch-npu.sh decider-0.8b,...     # or an explicit list
```
It runs the pinned server image (pulled if missing) with network, so the server
itself never needs it. `HALOGEN_MODELS` changes the base directory (default
`~/halogen-models`). After changing `HALOGEN_NPU_MODELS`, or after an image upgrade,
run it again: files that no longer match the image's record are fetched again.

One-time root steps. Run them in a host terminal, not inside a toolbox:
```bash
sudo ./host/halogen-host-setup.sh
```
It does three things:
1. **SELinux label**: `/dev/accel/accel0` is born `device_t`, which `container_t`
   cannot open; it is labelled `dri_device_t` (persistent `semanage fcontext` rule).
2. **GPU fabric clock**: installs `/usr/local/sbin/halogen-fabric-clock` and
   `halogen-fabric-clock.service`, which holds the clock at its top level at boot and
   after every resume (costs ~1 W). On Strix Halo, GPU and NPU work at the same time
   can hang the machine while that clock changes speed; rootless podman cannot hold
   it, so the server refuses to start without it.
3. **memlock**: the NPU pins ~12 GiB and a rootless container cannot exceed the limit
   of your `systemd --user`, so it adds `LimitMEMLOCK=infinity` to
   `user@<your UID>.service` only (no global `limits.conf` change) and applies it to
   the running instance.

To undo the clock hold: `sudo systemctl disable halogen-fabric-clock.service`, then
`sudo halogen-fabric-clock release` (or reboot).

## 3. Pull the images and pin the proxy

```bash
podman pull ghcr.io/peonist-ai/halogen-flash-server@sha256:fee7d5bb7ff02c78c60224da931e3c70a160dc48779bf5f7ba1030c97c8ac2d1
podman pull docker.io/alpine/socat@sha256:603174b77eebaba25ba8f8ebb15e1234d6600409554e95d6fb203fd106150287
```

## 4. Install the units

```bash
./install.sh
```

It first checks the prerequisites and stops if any is missing (the XRT libraries,
`~/halogen-models/npu`, the `dri_device_t` label, the held fabric clock and the
unlimited memlock). Then it labels `~/halogen-models` for SELinux if needed, stops
`halogen` if it was already running, copies the networks
and the `.container` files to `~/.config/containers/systemd/`, runs `daemon-reload`
and starts `halogen`. Quadlet generates `halogen.service`,
`halogen-proxy.service` and the networks. If something is
missing, check for syntax errors with:
```bash
/usr/libexec/podman/quadlet -dryrun -user
```

## 5. Start

`install.sh` already started it; later on:
```bash
systemctl --user start halogen          # also starts the proxy
journalctl --user -u halogen -f         # loading the model takes several minutes
```

`halogen` starts automatically when you log in (`WantedBy=default.target`).
To have it start at boot even if nobody logs in:
```bash
loginctl enable-linger $USER
```

## 6. Verify

That the API responds:
```bash
curl -s localhost:8731/v1/models
```

The API is compatible with OpenAI (`/v1/chat/completions`) and Anthropic (`/v1/messages`).

The NPU models (the log shows `halogen npu: ... files checked against this image's record`):
```bash
curl -s localhost:8731/v1/embeddings -H 'content-type: application/json' \
  -d '{"model":"qwen3-embedding-0.6b","input":["hello"]}' | head -c 200; echo
curl -s localhost:8731/v1/rerank -H 'content-type: application/json' \
  -d '{"model":"qwen3-reranker-0.6b","query":"NPU","documents":["The NPU is the neural processing unit","Bread recipe"]}'
curl -s localhost:8731/v1/chat/completions -H 'content-type: application/json' -d '{"model":"decider-0.8b",
  "messages":[{"role":"user","content":"WIN a FREE iPhone, click here"}],
  "response_format":{"type":"json_schema","json_schema":{"name":"spam","description":"Is this spam?","schema":{"enum":["no","yes"]}}}}'
curl -s localhost:8731/v1/audio/speech -H 'content-type: application/json' \
  -d '{"model":"qwen3-tts-1.7b-customvoice","input":"Hello from the NPU.","voice":"ryan","language":"english"}' -o hello.wav
curl -s localhost:8731/v1/audio/transcriptions -F model=qwen3-asr-1.7b -F file=@hello.wav
```

That it has **no** egress (both must fail):
```bash
podman exec halogen python3 -c "import urllib.request as u; u.urlopen('https://example.com', timeout=5)"
podman exec halogen python3 -c "import socket; socket.create_connection(('1.1.1.1', 53), timeout=5)"
```

That the port is not exposed to the network (only `127.0.0.1:8731` should show up):
```bash
ss -tlnp | grep 8731
```

## Using it from other machines

In `halogen-proxy.container`, change the address to your LAN interface IP:
```ini
PublishPort=192.168.0.X:8731:8731
```
The API has no authentication: anyone who can reach that port can use it.
Restrict it with firewalld to the IPs that need it.

## Known issues

- **`Segmentation fault` right after `preparing weights`**: the container is
  missing `--ipc=host` (see Isolation measures).
- **Write error on read-only filesystem**: the entrypoint writes to some path;
  add `Tmpfs=/that/path`.
- **The proxy cannot resolve `halogen-backend`**: the server has not started yet or
  is not on the `halogen-int` network (`podman network inspect halogen-int`).
- **OOM kill**: raise `--memory=` in `PodmanArgs` according to available RAM, or
  name fewer NPU models (the 0.6B ASR/TTS use about half the memory of the 1.7B).
- **`halogen npu: ... fabric clock is not held`**: run `sudo ./host/halogen-host-setup.sh`
  (check with `/usr/local/sbin/halogen-fabric-clock status`).
- **NPU fails to pin memory / `install.sh` says memlock is limited**: run
  `sudo ./host/halogen-host-setup.sh`; check with
  `prlimit --pid $(systemctl show -p MainPID --value user@$(id -u).service) --memlock`.
- **`halogen npu: ... cannot open it` / AVC denials on `/dev/accel/accel0`**: the
  SELinux label is missing; `ls -Z /dev/accel/accel0` must show `dri_device_t`.
- **`halogen npu: <model> is missing ...`**: run `./halogen-fetch-npu.sh`.
- **NPU fault (`aie2_tdr_work` in `dmesg`)**: the server restarts the NPU engine by
  itself (up to `HALOGEN_NPU_RESTARTS`, 3) while the Flash model keeps serving.

## Extra hardening (optional)

1. **Dedicated user**: create a `halogen` system user (groups `render`, `video`),
   move the models to `/srv/halogen-models`, and install the units in
   `~halogen/.config/containers/systemd/` with `loginctl enable-linger halogen`.
   This is the strongest option: fully separated from your session (and frees the
   `--ipc=host` from sharing anything with it).

## Upgrading

1. Get the digest of the new version without pulling it:
   ```bash
   skopeo inspect --format '{{.Digest}}' docker://ghcr.io/peonist-ai/halogen-flash-server:<version>
   ```
2. Replace the `Image=...@sha256:` in `halogen.container`, run `./halogen-fetch-npu.sh`
   (a new image may record new NPU files), `./install.sh` and restart.
3. To roll back, restore the previous digest. Previous Qwen images: 0.18.15
   `sha256:cde6ae91ab3497a470c848fd5c509b0f4af659a1dea7e74b8789df82cde0510e`, 0.18.14
   `sha256:e0c1d1b48e07c8acdd204fbdbafbb421a395a73cf704271845a1846ad1fd767f`
   (an older image may not know every NPU model in the list).

## License

MIT, see [LICENSE](LICENSE). This covers the files in this repository only, except
`host/halogen-fabric-clock` and `host/halogen-fabric-clock.service`, which are shipped
unchanged from [halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server)
and keep its license. The `halogen-flash-server` image, the `flash_serve` binary and
the model weights are not part of this repository and have their own terms.
