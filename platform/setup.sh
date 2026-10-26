#!/usr/bin/env bash
# "Connected side" of the course: run once with internet; afterwards everything runs offline.
# Idempotent and resumable: every step skips what is already present. Never uses sudo.
#   1 venvs (uv)  2 CLI tools (~/.local/bin)  3 models  4 images  5 course images (stack.sh build)
# Env: AIINFRA_CACHE (default ~/.cache/aiinfra-course)  SETUP_SKIP="images models tools venv build"
set -uo pipefail
PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COURSE_DIR="$(cd "$PLATFORM_DIR/.." && pwd)"
set -a; source "$PLATFORM_DIR/versions.env"; set +a
export PATH="$HOME/.local/bin:$PATH"
CACHE="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}"
BIN="$HOME/.local/bin"; mkdir -p "$BIN" "$CACHE/models" "$CACHE/hf/hub"
ARCH=$(uname -m); case "$ARCH" in aarch64|arm64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; esac
log() { echo "setup.sh: $*"; }
skip() { [[ " ${SETUP_SKIP:-} " == *" $1 "* ]]; }
rc=0; warn() { log "WARN $*"; rc=1; }

fix_ownership() {
  # A container (e.g. vLLM as root) may have written root-owned files into the cache.
  if [ -n "$(find "$CACHE" ! -user "$(id -un)" -print -quit 2>/dev/null)" ]; then
    log "fixing root-owned files in $CACHE (throwaway container chown, no sudo)"
    docker image inspect "$PYTHON_IMAGE" >/dev/null 2>&1 || docker pull -q "$PYTHON_IMAGE" >/dev/null
    docker run --rm --label course=aiinfra --entrypoint chown -v "$CACHE:/c" "$PYTHON_IMAGE" \
      -R "$(id -u):$(id -g)" /c || warn "chown via container failed"
  fi
}

step_venv() {
  command -v uv >/dev/null || { warn "uv not installed (https://docs.astral.sh/uv/)"; return; }
  local V="$PLATFORM_DIR/.venv" A="$PLATFORM_DIR/.venv-aider"
  if ! "$V/bin/python" -c 'import huggingface_hub,openai,mcp,safetensors,picklescan,boto3,qdrant_client,prometheus_client,yaml,requests' 2>/dev/null; then
    log "creating $V"
    uv venv --python 3.12 "$V" >/dev/null && uv pip install --python "$V/bin/python" -q \
      "huggingface_hub==$HUGGINGFACE_HUB_VERSION" "mcp==$MCP_VERSION" openai safetensors picklescan boto3 \
      qdrant-client prometheus-client pyyaml requests || warn "core venv install failed"
  else log "venv ok"; fi
  if ! "$A/bin/aider" --version 2>/dev/null | grep -q "$AIDER_CHAT_VERSION"; then
    log "creating $A (aider-chat $AIDER_CHAT_VERSION)"
    uv venv --python 3.12 "$A" >/dev/null && uv pip install --python "$A/bin/python" -q "aider-chat==$AIDER_CHAT_VERSION" \
      || warn "aider venv install failed (optional)"
  else log "venv-aider ok"; fi
}

step_tools() {
  local tmp
  if ! kind version 2>/dev/null | grep -q "$KIND_VERSION"; then
    curl -fsSLo "$BIN/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" && chmod +x "$BIN/kind" || warn "kind download"; fi
  if ! command -v kubectl >/dev/null; then
    curl -fsSLo "$BIN/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" && chmod +x "$BIN/kubectl" || warn "kubectl download"; fi
  if ! command -v helm >/dev/null; then
    tmp=$(mktemp -d); curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar -xz -C "$tmp" \
      && mv "$tmp/linux-${ARCH}/helm" "$BIN/helm" || warn "helm download"; rm -rf "$tmp"; fi
  if ! command -v kubeconform >/dev/null; then
    log "installing kubeconform $KUBECONFORM_VERSION"
    tmp=$(mktemp -d); curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" | tar -xz -C "$tmp" \
      && install -m755 "$tmp/kubeconform" "$BIN/kubeconform" || warn "kubeconform download"; rm -rf "$tmp"; fi
  if ! oras version 2>/dev/null | grep -q "$ORAS_VERSION"; then
    log "installing oras $ORAS_VERSION"
    tmp=$(mktemp -d); curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${ARCH}.tar.gz" | tar -xz -C "$tmp" \
      && install -m755 "$tmp/oras" "$BIN/oras" || warn "oras download"; rm -rf "$tmp"; fi
  for t in kind kubectl helm oras; do
    command -v $t >/dev/null && log "$t: $($t version 2>&1 | head -1 | cut -c1-60)" || log "$t: MISSING"; done
  command -v kubeconform >/dev/null && log "kubeconform: $(kubeconform -v 2>&1 | head -1)" || log "kubeconform: MISSING"
}

step_models() {
  local hf="$PLATFORM_DIR/.venv/bin/hf"
  [ -x "$hf" ] || { warn "hf CLI missing (venv step failed?)"; return; }
  export HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_TELEMETRY=1
  # Canonical HF cache = $CACHE/hf/hub (vLLM: HF_HOME=$CACHE/hf; hf-mirror serves it). Migrate WP0 layout.
  if ls "$CACHE"/hf/models--* >/dev/null 2>&1; then
    log "migrating HF snapshots into $CACHE/hf/hub"
    for d in "$CACHE"/hf/models--*; do [ -e "$CACHE/hf/hub/$(basename "$d")" ] || mv "$d" "$CACHE/hf/hub/"; done
  fi
  local kind name repo spec inc a args
  while IFS='|' read -r kind name repo spec; do
    case "$kind" in ''|\#*) continue ;; esac
    case "$kind" in
      gguf)
        if [ -s "$CACHE/models/$spec" ]; then log "model $name present"; continue; fi
        log "downloading $repo/$spec"
        "$hf" download "$repo" --include "$spec" --local-dir "$CACHE/models" >/dev/null 2>&1 \
          && [ -s "$CACHE/models/$spec" ] || warn "download failed: $repo/$spec" ;;
      hf)
        args=(); IFS=, read -ra inc <<< "$spec"; for a in "${inc[@]}"; do args+=(--include "$a"); done
        if HF_HUB_OFFLINE=1 HF_HUB_CACHE="$CACHE/hf/hub" "$hf" download "$repo" "${args[@]}" >/dev/null 2>&1; then
          log "model $name present"; continue; fi
        log "downloading $repo ${spec}"
        HF_HUB_CACHE="$CACHE/hf/hub" "$hf" download "$repo" "${args[@]}" >/dev/null 2>&1 || warn "download failed: $repo" ;;
    esac
  done < "$PLATFORM_DIR/models.txt"
  # SHA256SUMS for the GGUF files (modules verify integrity against it)
  ( cd "$CACHE/models" && for f in *.gguf; do [ -e "$f" ] || continue
      grep -q "  $f\$" SHA256SUMS 2>/dev/null || sha256sum "$f" >> SHA256SUMS; done ) 2>/dev/null
}

IMAGES=(LLAMACPP LITELLM PGVECTOR VALKEY OPENWEBUI LANGFUSE_WEB LANGFUSE_WORKER CLICKHOUSE SEAWEEDFS REGISTRY QDRANT PROMETHEUS GRAFANA KIND_NODE VLLM_CPU)
step_images() {
  local v img dig repo
  for v in "${IMAGES[@]}"; do
    img=$(eval echo "\$${v}_IMAGE"); dig=$(eval echo "\$${v}_DIGEST"); repo=${img%:*}
    if docker image inspect "$img" >/dev/null 2>&1; then log "image present: $img"; continue; fi
    log "pulling $img@${dig:0:19}... (resumable; re-run if interrupted)"
    if docker pull -q "$repo@$dig" >/dev/null && docker tag "$repo@$dig" "$img"; then :; else warn "pull failed: $img"; fi
  done
  docker image inspect "$PYTHON_IMAGE" >/dev/null 2>&1 && log "image present: $PYTHON_IMAGE" \
    || { docker pull -q "$PYTHON_IMAGE" >/dev/null || warn "pull failed: $PYTHON_IMAGE"; }
}

step_build() {
  if docker image inspect "$MOCK_IMAGE" >/dev/null 2>&1 && docker image inspect "$TRIPWIRE_IMAGE" >/dev/null 2>&1; then
    log "course images present ($MOCK_IMAGE, $TRIPWIRE_IMAGE); rebuild with platform/stack.sh build"
  else "$PLATFORM_DIR/stack.sh" build || warn "stack.sh build failed"; fi
}

docker info >/dev/null 2>&1 || { echo "setup.sh: docker not reachable" >&2; exit 1; }
fix_ownership
skip venv   || step_venv
skip tools  || step_tools
skip models || { fix_ownership; step_models; }
skip images || step_images
skip build  || step_build
fix_ownership
[ $rc = 0 ] && log "done" || log "done with warnings (re-run to resume)"
exit $rc
