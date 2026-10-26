#!/usr/bin/env bash
# Environment health check for the AI-infra course host. Read-only: changes nothing.
# Exit code: 0 if no FAIL, 1 otherwise. WARNs do not fail.
set -uo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$PLATFORM_DIR/versions.env"
export PATH="$HOME/.local/bin:$PATH"
TAILSCALE_IP="${TAILSCALE_IP:-100.127.87.65}"
CACHE="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}"
NON_COURSE=(cli-proxy-api workout-mongo kali-cli)

n_ok=0; n_warn=0; n_fail=0
ok()   { n_ok=$((n_ok+1));     printf '  [OK]   %s\n' "$*"; }
warn() { n_warn=$((n_warn+1)); printf '  [WARN] %s\n' "$*"; }
bad()  { n_fail=$((n_fail+1)); printf '  [FAIL] %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }

hdr "Docker"
if docker info >/dev/null 2>&1; then
  ok "docker daemon reachable ($(docker version -f '{{.Server.Version}}' 2>/dev/null), arch $(docker info -f '{{.Architecture}}' 2>/dev/null))"
  docker_ok=1
else
  bad "docker daemon not reachable (is the user in the docker group? is dockerd running?)"; docker_ok=0
fi
if docker compose version >/dev/null 2>&1; then ok "docker compose $(docker compose version --short)"
else bad "docker compose plugin missing"; fi

hdr "CLI tools and Python"
check_tool() { # name expected-version version-command...
  local name="$1" want="$2"; shift 2
  if ! command -v "$name" >/dev/null 2>&1; then warn "$name not installed (run platform/setup.sh)"; return; fi
  local got; got=$("$@" 2>/dev/null | head -1)
  if [[ "$got" == *"${want#v}"* ]]; then ok "$name $want"; else warn "$name version '$got' (pinned: $want; run platform/setup.sh)"; fi
}
check_tool kind        "$KIND_VERSION"        kind version
check_tool kubectl     "$KUBECTL_VERSION"     kubectl version --client
check_tool helm        "$HELM_VERSION"        helm version --short
check_tool kubeconform "$KUBECONFORM_VERSION" kubeconform -v
check_tool oras        "$ORAS_VERSION"        oras version
for t in jq curl python3 uv flock; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t present"; else bad "$t missing"; fi
done
if [ -x "$PLATFORM_DIR/.venv/bin/hf" ]; then
  v=$("$PLATFORM_DIR/.venv/bin/python" -c 'import huggingface_hub;print(huggingface_hub.__version__)' 2>/dev/null)
  [ "$v" = "$HUGGINGFACE_HUB_VERSION" ] && ok "platform/.venv (huggingface_hub $v)" || warn "platform/.venv huggingface_hub '$v' (pinned $HUGGINGFACE_HUB_VERSION)"
else warn "platform/.venv missing (run platform/setup.sh)"; fi
if [ -x "$PLATFORM_DIR/.venv-aider/bin/aider" ]; then ok "platform/.venv-aider present"; else warn "platform/.venv-aider missing (optional, module with Aider)"; fi

hdr "Images (pull_policy: never; run platform/setup.sh if missing)"
if [ "$docker_ok" = 1 ]; then
  missing=0
  for v in LLAMACPP VLLM_CPU LITELLM PGVECTOR VALKEY OPENWEBUI LANGFUSE_WEB LANGFUSE_WORKER CLICKHOUSE SEAWEEDFS REGISTRY QDRANT PROMETHEUS GRAFANA KIND_NODE; do
    img=$(eval echo "\$${v}_IMAGE")
    docker image inspect "$img" >/dev/null 2>&1 || { bad "image missing: $img"; missing=$((missing+1)); }
  done
  for img in "$PYTHON_IMAGE" "$ALPINE_IMAGE"; do docker image inspect "$img" >/dev/null 2>&1 || { bad "image missing: $img"; missing=$((missing+1)); }; done
  [ "$missing" -eq 0 ] && ok "all pinned images present"
  for img in "$MOCK_IMAGE" "$TRIPWIRE_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 && ok "course image $img" || warn "course image $img missing (platform/stack.sh build)"
  done
fi

hdr "Models ($CACHE)"
nm=0
for f in qwen2.5-0.5b-instruct-q4_k_m.gguf qwen2.5-0.5b-instruct-q8_0.gguf Qwen2.5-Coder-0.5B-Q4_K_M.gguf Qwen2.5-Coder-0.5B-Q8_0.gguf bge-small-en-v1.5-q4_k_m.gguf bge-small-en-v1.5-q8_0.gguf; do
  [ -s "$CACHE/models/$f" ] || { bad "model missing: $f (platform/setup.sh)"; nm=$((nm+1)); }
done
for r in HuggingFaceTB--SmolLM2-360M-Instruct Qwen--Qwen2.5-0.5B-Instruct; do
  ls -d "$CACHE/hf/hub/models--$r" >/dev/null 2>&1 || { warn "HF snapshot missing: $r (platform/setup.sh)"; nm=$((nm+1)); }
done
[ "$nm" -eq 0 ] && ok "GGUF files and HF snapshots present"
if [ -n "$(find "$CACHE" ! -user "$(id -un)" -print -quit 2>/dev/null)" ]; then
  warn "root-owned files in $CACHE (platform/setup.sh fixes them via a throwaway container)"
else ok "cache owned by $(id -un)"; fi

hdr "Resources"
avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
if   [ "$avail_mb" -ge 6000 ]; then ok "available RAM ${avail_mb} MB"
elif [ "$avail_mb" -ge 3000 ]; then warn "available RAM ${avail_mb} MB (< 6 GB: avoid lf/vllm, stop other work)"
else bad "available RAM ${avail_mb} MB (< 3 GB: the stack will be unstable)"; fi
docker_root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
[ -d "$docker_root" ] || docker_root=/
free_gb=$(df -Pk "$docker_root" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')
if   [ "${free_gb:-0}" -ge 40 ]; then ok "free disk ${free_gb} GB (on $docker_root filesystem)"
elif [ "${free_gb:-0}" -ge 25 ]; then warn "free disk ${free_gb} GB (images ~20 GB + models + volumes)"
else bad "free disk ${free_gb:-?} GB"; fi
cpus=$(nproc); ok "CPUs: $cpus, arch $(uname -m)"
[ "$(uname -m)" = aarch64 ] || warn "host arch is $(uname -m); course images are pinned for arm64 (multi-arch should still work)"
if [ "$docker_ok" = 1 ]; then
  ids=$(docker ps -q --filter label=course=aiinfra)
  if [ -n "$ids" ]; then
    mb=$(docker stats --no-stream --format '{{.MemUsage}}' $ids 2>/dev/null | awk '{v=$1; if (v ~ /GiB/) {sub(/GiB/,"",v); s+=v*1024} else if (v ~ /MiB/) {sub(/MiB/,"",v); s+=v} else if (v ~ /KiB/) {sub(/KiB/,"",v); s+=v/1024}} END {print int(s)}')
    if [ "${mb:-0}" -gt 8192 ]; then warn "course containers use ${mb} MB (> 8 GB budget)"; else ok "course containers use ${mb:-0} MB (budget 8 GB)"; fi
  fi
fi

hdr "Network"
if ip -4 -o addr show 2>/dev/null | grep -qw "$TAILSCALE_IP"; then ok "Tailscale IP $TAILSCALE_IP present (UIs published there)"
else warn "Tailscale IP $TAILSCALE_IP not on this host; stack.sh will publish UIs on 127.0.0.1 only"; fi

hdr "Course ports (18000-18199)"
PORTS="18011:llama-chat 18012:llama-coder 18013:llama-embed 18021:mock-vllm-a 18022:mock-vllm-b 18023:vllm-cpu 18030:grafana 18031:mock-dcgm-a 18032:mock-dcgm-b 18033:qdrant 18040:litellm 18041:litellm-2 18050:registry 18054:postgres 18060:langfuse 18063:valkey 18070:seaweedfs 18071:hf-mirror 18072:tripwire 18080:open-webui 18090:prometheus"
for p in $(seq 18100 18110); do PORTS="$PORTS $p:kind-nodeport"; done
course_ports=""
if [ "$docker_ok" = 1 ]; then
  ids=$(docker ps -q --filter label=course=aiinfra; docker ps -q --filter label=io.x-k8s.kind.cluster=aiinfra)
  [ -n "$ids" ] && course_ports=$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}} {{end}}{{end}}' $ids | tr ' ' '\n' | sort -u | tr '\n' ' ')
fi
listening=$(ss -Htln 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')
conflicts=0
for pair in $PORTS; do
  p=${pair%%:*}; svc=${pair#*:}
  if [[ " $listening " == *" $p "* ]] && [[ " $course_ports " != *" $p "* ]]; then
    bad "port $p ($svc) is in use by a non-course process"; conflicts=$((conflicts+1))
  fi
done
[ "$conflicts" -eq 0 ] && ok "no conflicts on course ports (free or owned by course containers)"

hdr "Lab lock"
LOCK=/tmp/aiinfra-course-lab.lock
if [ -e "$LOCK" ] && ! ( exec 8>"$LOCK"; flock -n 8 ) 2>/dev/null; then
  warn "lab lock is held: $(cat /tmp/aiinfra-course-lab.owner 2>/dev/null || echo 'owner unknown'); lab-session.sh will wait"
else ok "lab lock free"; fi

hdr "Course containers (label course=aiinfra)"
if [ "$docker_ok" = 1 ]; then
  rows=$(docker ps -a --filter label=course=aiinfra --format '{{.Names}}|{{.State}}|{{.Status}}')
  if [ -z "$rows" ]; then ok "none (stack down)"; fi
  while IFS='|' read -r name state status; do
    [ -z "$name" ] && continue
    if [[ "$status" == *"(unhealthy)"* ]] || [[ "$state" == restarting ]]; then bad "$name: $status"
    elif [ "$state" = exited ] && [[ "$status" != *"Exited (0)"* ]]; then warn "$name: $status"
    elif [ "$state" != running ] && [ "$state" != exited ]; then warn "$name: $status"
    elif [[ "$status" == *"health: starting"* ]]; then warn "$name: $status"
    else ok "$name: $status"; fi
  done <<< "$rows"
  ok "course volumes: $(docker volume ls -q --filter label=course=aiinfra | wc -l), networks: $(docker network ls -q --filter label=course=aiinfra | wc -l)"

  hdr "Pre-existing (non-course) containers - must stay untouched"
  for c in "${NON_COURSE[@]}"; do
    st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
    if [ "$st" = running ]; then ok "$c running"; else warn "$c: $st (not course-owned; do not manage it)"; fi
  done

  hdr "Profile health (only for what is up)"
  svc_up() { docker ps --filter label=com.docker.compose.project=aiinfra --filter "label=com.docker.compose.service=$1" -q | grep -q .; }
  probe() { # service url desc
    svc_up "$1" || return 0
    if curl -fsS -o /dev/null --max-time 5 "$2" 2>/dev/null; then ok "$3 answers ($2)"; else bad "$3 not answering ($2)"; fi
  }
  probe litellm        http://127.0.0.1:18040/health/liveliness "litellm"
  probe llama-chat     http://127.0.0.1:18011/health            "llama-chat"
  probe llama-coder    http://127.0.0.1:18012/health            "llama-coder"
  probe llama-embed    http://127.0.0.1:18013/health            "llama-embed"
  probe prometheus     http://127.0.0.1:18090/-/ready           "prometheus"
  probe grafana        http://127.0.0.1:18030/api/health        "grafana"
  probe open-webui     http://127.0.0.1:18080/health            "open-webui"
  probe qdrant         http://127.0.0.1:18033/readyz            "qdrant"
  probe registry       http://127.0.0.1:18050/v2/               "registry"
  probe hf-mirror      http://127.0.0.1:18071/health            "hf-mirror"
  probe tripwire       http://127.0.0.1:18072/hits              "tripwire"
  probe langfuse-web   http://127.0.0.1:18060/api/public/health "langfuse"
  probe vllm-cpu       http://127.0.0.1:18023/health            "vllm-cpu"
  probe mock-vllm-a    http://127.0.0.1:18021/health            "mock-vllm-a"
  probe mock-vllm-b    http://127.0.0.1:18022/health            "mock-vllm-b"
  if svc_up prometheus; then
    down_t=$(curl -fsS --max-time 5 http://127.0.0.1:18090/api/v1/targets 2>/dev/null | jq -r '[.data.activeTargets[]|select(.health!="up")]|length' 2>/dev/null)
    [ "${down_t:-0}" = 0 ] && ok "prometheus: all targets up" || warn "prometheus: ${down_t} target(s) not up (may be a still-starting service)"
  fi
  if svc_up llama-chat && { svc_up langfuse-web || svc_up vllm-cpu; }; then bad "RAM rule violated: llm together with lf/vllm"; fi
fi

hdr "kind cluster"
if command -v kind >/dev/null 2>&1; then
  if kind get clusters 2>/dev/null | grep -qx aiinfra; then
    if kubectl --context kind-aiinfra get nodes --no-headers >/dev/null 2>&1; then
      ok "kind cluster 'aiinfra' up: $(kubectl --context kind-aiinfra get nodes --no-headers 2>/dev/null | awk '{print $1"="$2}' | tr '\n' ' ')"
    else
      bad "kind cluster 'aiinfra' exists but API not reachable"
    fi
    if [ "$docker_ok" = 1 ] && docker ps -q --filter label=com.docker.compose.service=llama-chat | grep -q .; then
      bad "kind cluster and profile llm both running (RAM rule)"
    fi
  else
    ok "kind cluster 'aiinfra' not running"
  fi
fi

printf '\nSummary: %d OK, %d WARN, %d FAIL\n' "$n_ok" "$n_warn" "$n_fail"
[ "$n_fail" -eq 0 ]
