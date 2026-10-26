#!/usr/bin/env bash
# Reference method for module 02 (what a learner does with hf / sha256sum / docker / oras / python).
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; PY="$PLATFORM_DIR/.venv/bin/python"; HF="$PLATFORM_DIR/.venv/bin/hf"; CACHE="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}"
REPO=$(env_kv "$LAB/REPOS.env" REPO); COMMIT=$(env_kv "$LAB/REPOS.env" COMMIT); GGUF=$(env_kv "$LAB/REPOS.env" GGUF_FILE)
export HF_ENDPOINT="$HFMIRROR_URL" HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_TELEMETRY=1
INC=(--include "*.json" --include "*.txt" --include "*.safetensors")
# 2.1 download, manifest, header numbers
"$HF" download "$REPO" --revision "$COMMIT" "${INC[@]}" --local-dir "$LAB/model" >/dev/null || exit 1
( cd "$LAB/model" && find . -type f -not -path './.cache/*' | sed 's|^\./||' | sort | xargs sha256sum ) > "$LAB/model.sha256"
"$PY" - "$LAB" <<'PY'
import json, struct, sys, os
lab = sys.argv[1]; idx = json.load(open(lab + "/model/model.safetensors.index.json"))
shards = sorted(set(idx["weight_map"].values())); tensors = 0; params = 0; dts = set()
for s in shards:
    with open(f"{lab}/model/{s}", "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]; h = json.loads(f.read(n))
    for k, v in h.items():
        if k == "__metadata__": continue
        tensors += 1; dts.add(v["dtype"]); p = 1
        for d in v["shape"]: p *= d
        params += p
json.dump({"shards": len(shards), "tensors": tensors, "total_params": params, "dtypes": sorted(dts)}, open(lab + "/answers/header.json", "w"), indent=1)
PY
# 2.4 populate an HF cache for the offline loader (HF_HOME layout)
HF_HOME="$LAB/hf-cache" "$HF" download "$REPO" --revision "$COMMIT" "${INC[@]}" >/dev/null || exit 1
# 2.5 registry: image by digest, model as OCI artifact
TAG=localhost:18050/aiinfra/llama:server-b11889
docker tag "$LLAMACPP_IMAGE" "$TAG" && docker push "$TAG" >/dev/null || exit 1
ACC='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
IMAGE_DIGEST=$(curl -sI -H "Accept: $ACC" "$REGISTRY_URL/v2/aiinfra/llama/manifests/server-b11889" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
docker rm -f aiinfra-lab02-llama-digest >/dev/null 2>&1
docker run -d --name aiinfra-lab02-llama-digest --label course=aiinfra --label module=02 -p 127.0.0.1:18126:8080 -v "$CACHE/models:/models:ro" \
  "localhost:18050/aiinfra/llama@$IMAGE_DIGEST" -m "/models/$GGUF" --host 0.0.0.0 --port 8080 -c 1024 -t 1 >/dev/null || exit 1
( cd "$CACHE/models" && oras push --plain-http --artifact-type application/vnd.aiinfra.model.v1 127.0.0.1:18050/aiinfra/models/gguf:q4 "$GGUF:application/vnd.aiinfra.gguf" ) > /tmp/aiinfra-02-oras.txt 2>&1 || { cat /tmp/aiinfra-02-oras.txt; exit 1; }
ARTIFACT_DIGEST=$(grep -o 'sha256:[0-9a-f]*' /tmp/aiinfra-02-oras.txt | tail -1); rm -f /tmp/aiinfra-02-oras.txt
printf 'IMAGE_DIGEST=%s\nARTIFACT_DIGEST=%s\nGGUF_SHA256=%s\n' "$IMAGE_DIGEST" "$ARTIFACT_DIGEST" "$(sha256sum "$CACHE/models/$GGUF" | cut -d' ' -f1)" > "$LAB/registry/answers.env"
# 2.6 diagnose the bundle, then repair only what is broken
cd "$LAB/incoming" || exit 1
missing=(); corrupt=()
while read -r h f; do
  if [ ! -f "$f" ]; then missing+=("$f"); else a=$(sha256sum "$f" | cut -d' ' -f1); [ "$a" = "$h" ] || corrupt+=("$f $h $a"); fi
done < SHA256SUMS
jq -n --argjson m "$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)" --argjson c "$(printf '%s\n' "${corrupt[@]}" | jq -R 'split(" ") | {file:.[0], expected_sha256:.[1], actual_sha256:.[2]}' | jq -s .)" '{missing:$m, corrupt:$c}' > "$LAB/answers/incident.json"
args=(); for f in "${missing[@]}"; do args+=(--include "$f"); done; for c in "${corrupt[@]}"; do args+=(--include "${c%% *}"); done
"$HF" download "$REPO" --revision "$COMMIT" "${args[@]}" --local-dir "$LAB/incoming" >/dev/null || exit 1
