#!/usr/bin/env bash
#
# serve-qwen36-35b-a3b-dflash.sh
# Serve RedHatAI/Qwen3.6-35B-A3B-NVFP4 with DFlash speculative decoding on an
# NVIDIA DGX Spark (GB10, sm_121), via vLLM in Docker.
#
# Standalone launcher (everything in one file — no serve.sh dependency):
#   1. Pre-stage BOTH the target weights and the DFlash draft model once into a
#      host-mounted HF cache ("download once, mount everywhere").
#   2. Launch the long-running OpenAI-compatible server, agentic-ready by default.
#   3. Stream load logs, wait for readiness, then warm the JIT before first use.
#
# Configured for: 64K context, DFlash speculative decoding, agentic/tool-calling
# workloads, single Spark.
#
# ----------------------------------------------------------------------------
# Design decisions (and why):
#   - DFlash speculative decoding: a 0.5B bidirectional drafter (z-lab) drafts a
#     whole block per step; vLLM verifies it against the target in one pass. The
#     drafter and its KV live INSIDE the gpu-memory-utilization fraction, not
#     outside it, so they contend with the target KV cache.
#   - gpu-memory-utilization = 0.45 (~58 GB): sized to share the 128 GB unified
#     pool with a second model running side-by-side (2 x ~0.45 leaves headroom for
#     the host). Target weights (~20 GB NVFP4) + the 0.5B drafter (~1 GB) + KV all
#     live inside this fraction, leaving a ~36 GB KV pool. Raise toward 0.85 if you
#     run this model alone and want the larger context below.
#   - max-model-len = 32768 (32K): scaled down to the smaller KV pool. fp8 KV at
#     GMU 0.85 gave a ~125K-token pool (64K context with room for a 2nd stream);
#     at GMU 0.45 the ~36 GB pool holds ~52K tokens, so 32K fits one full-context
#     stream with headroom for a partial second.
#   - kv-cache-dtype = fp8 (+ --calculate-kv-scales): fp8 ~halves cache bytes/token,
#     ~doubling the KV pool so 32K fits comfortably in the reduced fraction. The
#     checkpoint ships no KV scaling factors, so --calculate-kv-scales computes them
#     on the fly during prefill rather than falling back to scale=1.0 (overflow risk).
#   - max-num-seqs = 2: matches the ~52K-token KV pool (~1.5 full-context 32K
#     streams). A ceiling, not a reservation — vLLM pages/preempts above it. Also
#     stays under Spark's bandwidth ceiling where >4 decode streams spike TTFT.
#   - max-num-batched-tokens = 16384: prefill chunk halved alongside the pool to
#     shrink the activation working set; still raises prefill throughput and gives
#     the drafter context per step, but with a smaller peak footprint under the
#     tighter memory budget.
#   - --load-format fastsafetensors: GPUDirect Storage accelerated weight loading
#     for a faster cold start from NVMe.
#   - torch.compile cache is persisted (mounted) so the compile is paid once.
#
# ----------------------------------------------------------------------------
# Image note: the default ghcr.io/spark-arena/dgx-vllm-eugr-nightly image is the
# patched DGX Spark build; its ENTRYPOINT is NOT `vllm serve`, so this script
# prepends `vllm serve` inside the docker run command.

set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
MODEL="${MODEL:-RedHatAI/Qwen3.6-35B-A3B-NVFP4}"
SERVED_NAME="${SERVED_NAME:-$MODEL}"   # canonical HF id so clients use it in the model field without remapping
DRAFT_MODEL="${DRAFT_MODEL:-z-lab/Qwen3.6-35B-A3B-DFlash}"  # DFlash drafter; pre-staged alongside the target
IMAGE="${IMAGE:-ghcr.io/spark-arena/dgx-vllm-eugr-nightly}"  # patched DGX Spark image (entrypoint is NOT `vllm serve`)
PORT="${PORT:-8000}"
# Host interface to publish the port on. 0.0.0.0 = reachable from other machines
# on the network (default). Set to 127.0.0.1 to restrict to this host only.
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
# API key for request auth. If not provided, a random one is generated so the
# endpoint is never unauthenticated by default. The key is printed at the end;
# clients send it as: Authorization: Bearer <key>
# Pin API_KEY=... if you want it stable across restarts.
API_KEY="${API_KEY:-}"
API_KEY_GENERATED=0
if [[ -z "$API_KEY" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    API_KEY="sk-$(openssl rand -hex 24)"
  elif command -v uuidgen >/dev/null 2>&1; then
    API_KEY="sk-$(uuidgen | tr -d '-')"
  else
    API_KEY="sk-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  API_KEY_GENERATED=1
fi
CONTAINER_NAME="${CONTAINER_NAME:-vllm-qwen36}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
# vLLM's torch.compile cache lives at /root/.cache/vllm inside the container;
# persisting it across restarts skips the compile on every boot.
VLLM_CACHE="${VLLM_CACHE:-$HOME/.cache/vllm}"
# z-lab recommends --shm-size=16g over --ipc=host for this image. On the Spark's
# unified memory this tmpfs is a lazy cap, not a reservation (single GB10 = no
# cross-GPU NCCL transfer, so actual /dev/shm use is small); --ipc=host is an
# equivalent alternative with no memory advantage either way. Set SHM_SIZE="" to
# fall back to --ipc=host.
SHM_SIZE="${SHM_SIZE:-16g}"

# Serving knobs tuned for Spark's unified-memory / small-batch profile (see the
# Design decisions header for the rationale behind each default).
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.45}"               # ~58 GB of the 128 GB pool — leaves room for a 2nd model side-by-side
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"            # 32K context (scaled down to the smaller KV pool)
MAX_NUM_SEQS="${MAX_NUM_SEQS:-2}"                  # matches the ~52K-token KV pool (~1.5 full-context streams)
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-16384}"  # prefill chunk; halved to shrink the activation working set
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"            # fp8 ~doubles the KV pool so 32K fits in the reduced fraction
NUM_SPEC_TOKENS="${NUM_SPEC_TOKENS:-15}"            # DFlash block depth (z-lab recommended)
SKIP_PRESTAGE="${SKIP_PRESTAGE:-0}"                 # set to 1 to skip weight pre-staging

# ---- Agentic flags ----------------------------------------------------------
# Agentic serving (tool calls + reasoning) is ON by default:
#   --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3
# Qwen3 uses the model's bundled chat template (no --chat-template override
# needed, unlike Gemma 4). The qwen3_coder tool-call format must match the
# model's output, and qwen3 strips/surfaces the <think> reasoning block.
#
# To DISABLE agentic flags entirely:  AGENTIC=0 ./serve-qwen36-35b-a3b-dflash.sh
# To override a parser:               TOOL_PARSER=... REASONING_PARSER=... ./serve-...
AGENTIC="${AGENTIC:-1}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
REASONING_PARSER="${REASONING_PARSER:-qwen3}"

AGENTIC_FLAGS=()
if [[ "$AGENTIC" != "0" ]]; then
  if [[ -n "$TOOL_PARSER" ]]; then
    AGENTIC_FLAGS+=(--enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER")
  fi
  if [[ -n "$REASONING_PARSER" ]]; then
    AGENTIC_FLAGS+=(--reasoning-parser "$REASONING_PARSER")
  fi
fi

# ---- Pre-flight -------------------------------------------------------------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "WARNING: HF_TOKEN is not set. Gated/private weights will fail to download." >&2
  echo "         export HF_TOKEN=hf_xxx   (then re-run)" >&2
fi

mkdir -p "$HF_CACHE" "$VLLM_CACHE"

# ---- Pre-stage weights ------------------------------------------------------
# "Download once, mount everywhere": fetch BOTH the target and the DFlash draft
# into the host-mounted HF cache BEFORE starting the server, so the first
# `vllm serve` boot is a load, not a download. Runs inside the SAME image vLLM
# serves from, so huggingface_hub versions match. Idempotent: cached files are
# skipped. Skip entirely with SKIP_PRESTAGE=1.
prestage() {
  local m="$1"
  echo "Pre-staging $m into $HF_CACHE ..."
  docker run --rm \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -e MODEL="$m" \
    -v "${HF_CACHE}:/root/.cache/huggingface" \
    --entrypoint bash \
    "$IMAGE" \
    -c 'if command -v hf >/dev/null 2>&1; then hf download "$MODEL"; else huggingface-cli download "$MODEL"; fi'
}
if [[ "$SKIP_PRESTAGE" != "1" ]]; then
  prestage "$MODEL"
  prestage "$DRAFT_MODEL"
  echo "Pre-stage complete."
else
  echo "Skipping pre-stage (SKIP_PRESTAGE=1); weights will load from existing cache."
fi

# ---- Launch -----------------------------------------------------------------
# Remove any existing container with the same name so docker run doesn't conflict.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Removing existing container '$CONTAINER_NAME'..."
  docker rm -f "$CONTAINER_NAME"
fi

echo "Starting vLLM container '$CONTAINER_NAME' serving $MODEL (DFlash, ${NUM_SPEC_TOKENS} spec tokens) ..."
if [[ ${#AGENTIC_FLAGS[@]} -gt 0 ]]; then
  echo "Agentic flags: ${AGENTIC_FLAGS[*]}"
else
  echo "Agentic flags: none (disabled via AGENTIC=0)"
fi

# Shared-memory: explicit --shm-size cap (z-lab recommended) or --ipc=host.
IPC_FLAGS=()
if [[ -n "$SHM_SIZE" ]]; then
  IPC_FLAGS=(--shm-size="$SHM_SIZE")
else
  IPC_FLAGS=(--ipc=host)
fi

# NOTE: the spark-arena image's ENTRYPOINT is NOT `vllm serve`, so we prepend it
# explicitly below (unlike the vllm/vllm-openai image used by the Gemma script).
docker run -d \
  --name "$CONTAINER_NAME" \
  "${IPC_FLAGS[@]}" \
  --restart unless-stopped \
  --gpus all \
  -p "${BIND_ADDR}:${PORT}:8000" \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  -v "${VLLM_CACHE}:/root/.cache/vllm" \
  "$IMAGE" \
  vllm serve \
  "$MODEL" \
    --served-model-name "$SERVED_NAME" \
    --gpu-memory-utilization "$GPU_MEM_UTIL" \
    --max-model-len "$MAX_MODEL_LEN" \
    --max-num-seqs "$MAX_NUM_SEQS" \
    --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
    --kv-cache-dtype "$KV_CACHE_DTYPE" \
    --calculate-kv-scales \
    --trust-remote-code \
    --enable-prefix-caching \
    --enable-chunked-prefill \
    --load-format fastsafetensors \
    --speculative-config "{\"method\":\"dflash\",\"num_speculative_tokens\":${NUM_SPEC_TOKENS},\"model\":\"${DRAFT_MODEL}\"}" \
    --api-key "$API_KEY" \
    ${AGENTIC_FLAGS[@]+"${AGENTIC_FLAGS[@]}"}

# ---- Wait for readiness -----------------------------------------------------
# With weights pre-staged, this boot is the safetensor LOAD (several minutes),
# not the download. The first *request* additionally triggers JIT codegen.
AUTH_HEADER="Authorization: Bearer ${API_KEY}"
echo "Waiting for the server to come up (weight load can take several minutes)..."
echo "Streaming container logs below (Ctrl-C stops the script, not the container):"
echo "------------------------------------------------------------------------------"

docker logs -f "$CONTAINER_NAME" 2>&1 &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

until curl -sf -H "$AUTH_HEADER" "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    kill "$LOG_PID" 2>/dev/null || true
    echo "------------------------------------------------------------------------------"
    echo "ERROR: container '$CONTAINER_NAME' exited during startup. Full logs:" >&2
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 50 >&2
    exit 1
  fi
  sleep 5
done

kill "$LOG_PID" 2>/dev/null || true
trap - EXIT
echo "------------------------------------------------------------------------------"

READY_ID="$(curl -sf -H "$AUTH_HEADER" "http://localhost:${PORT}/v1/models" | jq -r '.data[0].id' 2>/dev/null || true)"
echo "Server is up. Reported model id: ${READY_ID:-<unknown>}"

# ---- Pre-warm the JIT -------------------------------------------------------
# Fire a tiny request so the first real user request doesn't eat cold-start JIT.
echo "Pre-warming JIT with a 3-token request..."
curl -sf "http://localhost:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d "{\"model\":\"${SERVED_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" \
  >/dev/null && echo "Warm-up done." || echo "Warm-up request failed (server may still be loading)."

echo
echo "Ready. Local endpoint: http://localhost:${PORT}/v1"
echo "Metrics:               http://localhost:${PORT}/metrics"
echo "Logs:                  docker logs -f ${CONTAINER_NAME}"
echo
if [[ "$API_KEY_GENERATED" == "1" ]]; then
  echo "API key (auto-generated this run): ${API_KEY}"
  echo "  Pin it with API_KEY=... next run to keep it stable across restarts."
else
  echo "API key: (provided via API_KEY)"
fi
echo "  Clients must send:  Authorization: Bearer ${API_KEY}"
if [[ "$BIND_ADDR" == "0.0.0.0" ]]; then
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "Network endpoint:      http://${LAN_IP:-<this-host-ip>}:${PORT}/v1  (reachable from other machines)"
fi
