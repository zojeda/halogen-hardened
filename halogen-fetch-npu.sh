#!/bin/bash
# Downloads the NPU models to ~/halogen-models/npu in a throwaway container WITH network,
# so the server (halogen.service) stays without egress and with /models :ro.
# Uses the same image as the server: each file is fetched from the repo and commit the image
# records, and its sha256 is checked against /opt/halogen/npu/models.txt.
# The server checks them again at every start (HALOGEN_NPU_VERIFY=1).
#
# Usage: ./halogen-fetch-npu.sh [model,model,...]
#   Without an argument it uses HALOGEN_NPU_MODELS from halogen.container.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT="$DIR/halogen.container"
[ -f "$UNIT" ] || UNIT="$HOME/.config/containers/systemd/halogen.container"
IMAGE=$(sed -n 's/^Image=//p' "$UNIT")
MODELS="${1:-$(sed -n 's/^Environment=HALOGEN_NPU_MODELS=//p' "$UNIT")}"
DEST="${HALOGEN_MODELS:-$HOME/halogen-models}/npu"
[ -n "$IMAGE" ] && [ -n "$MODELS" ] || { echo "cannot find Image= or HALOGEN_NPU_MODELS in $UNIT" >&2; exit 1; }

mkdir -p "$DEST"
echo "image: $IMAGE"
echo "models: $MODELS -> $DEST"

podman run --rm --pull=missing \
  --read-only --tmpfs /tmp \
  --cap-drop=all --security-opt no-new-privileges \
  --pids-limit 256 --memory 4g \
  -e HF_HUB_OFFLINE=0 -e HF_HOME=/tmp/hf -e HF_HUB_DISABLE_TELEMETRY=1 -e HF_HUB_DISABLE_PROGRESS_BARS=1 \
  -e MODELS="$MODELS" \
  -v "$DEST":/models/npu:z \
  --entrypoint bash "$IMAGE" -euo pipefail -c '
    P=/opt/halogen/npu/models.txt
    get() { awk -v id="$1" -v k="$2" "\$1==\"model\" && \$2==id { for (i=3;i<=NF;i++) if (index(\$i, k \"=\")==1) { print substr(\$i, length(k)+2); exit } }" "$P"; }
    files() { awk -v id="$1" "\$1==\"file\" && \$2==id {print \$3, \$4, \$5}" "$P"; }

    # A model with devices=<other> runs on the device files of that other model: fetch both
    ids=""
    for id in $(echo "$MODELS" | tr , " "); do
      case "$id" in /*) echo "$id is a custom model (path); not downloaded"; continue ;; esac
      [ -n "$(get "$id" repo)" ] || { echo "the image does not know the model $id" >&2; exit 1; }
      ids="$ids $id"; dev=$(get "$id" devices); [ -n "$dev" ] && ids="$ids $dev"
    done
    ids=$(echo $ids | tr " " "\n" | awk "!s[\$0]++")

    for id in $ids; do
      d=/models/npu/$id; repo=$(get "$id" repo); rev=$(get "$id" revision); need=""
      while read -r p sz sha; do
        if [ -f "$d/$p" ] && [ "$(wc -c < "$d/$p")" = "$sz" ] && [ "$(sha256sum "$d/$p" | cut -d" " -f1)" = "$sha" ]; then continue; fi
        rm -f "$d/$p"; need="$need $p"
      done < <(files "$id")
      if [ -z "$need" ]; then echo "$id: ok (already present)"; continue; fi
      echo "$id: downloading from $repo@$rev:$need"
      mkdir -p "$d"
      hf download "$repo" $need --revision "$rev" --local-dir "$d" > /dev/null
      while read -r p sz sha; do
        [ "$(sha256sum "$d/$p" | cut -d" " -f1)" = "$sha" ] || { echo "$id: $p does not match the recorded sha256" >&2; exit 1; }
      done < <(files "$id")
      rm -rf "$d/.cache"
      echo "$id: ok ($(files "$id" | wc -l) files verified)"
    done
  '
chmod -R a+rX "$DEST"
du -sh "$DEST"/*
