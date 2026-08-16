#!/usr/bin/env bash
#
# serve-qwen38-27b-mtp.sh
# Serve unsloth/Qwen3.8-27B-NVFP4 with its built-in MTP (Multi-Token
# Prediction) speculative decoding on an NVIDIA DGX Spark (GB10, sm_121),
# via vLLM in Docker.
#
# Standalone launcher (everything in one file — no serve.sh dependency):
#   1. Pre-stage the NVFP4 weights once into a host-mounted HF cache
#      ("download once, mount everywhere"). Unlike the Qwen3.6 DFlash recipe,
#      MTP's draft head ships INSIDE the checkpoint — no separate draft model.
#   2. Launch the long-running OpenAI-compatible server, agentic-ready by default.
#   3. Stream load logs, wait for readiness, then warm the JIT before first use.
#
# Configured for: 262K native context, MTP speculative decoding, agentic/
# tool-calling workloads, single Spark.
#
# ----------------------------------------------------------------------------
# Design decisions (and why):
#   - MTP speculative decoding: Qwen3.8-27B ships a built-in Multi-Token
#     Prediction draft head in the checkpoint itself, so --speculative-config
#     needs no "model" key (unlike the Qwen3.6 DFlash recipe's separate z-lab
#     drafter). --num-speculative-tokens=5 matches the config measured working
#     on a single DGX Spark (see the NVIDIA developer forum thread referenced
#     in the README); vLLM's own recipe page suggests 3 as a lighter starting
#     point if 5 underperforms for your traffic shape.
#   - gpu-memory-utilization = 0.45 (~58 GB): sized to share the 128 GB unified
#     pool with a second model running side-by-side (2 x ~0.45 leaves headroom
#     for the host), matching this folder's other Spark recipes. NVFP4 weights
#     (~24.6 GiB) + activations + KV all live inside this fraction. Measured on
#     Spark: weights+overhead 26.16 GiB, peak activation 1.80 GiB, KV cache
#     27.56 GiB — comfortably fits the FULL 262144-token native context at this
#     utilization, so (unlike the Qwen3.6 script) context does NOT need to be
#     scaled down for the shared-box default. Raise toward 0.85 to run this
#     model alone with more concurrency, or ~0.60 to unlock 1M-token YaRN
#     context scaling (see README).
#   - max-model-len = 262144: the model's native context window; fits inside
#     the 0.45 utilization fraction above without KV pressure.
#   - kv-cache-dtype = auto (default): the measured-working Spark config used
#     the default (full-precision) KV cache — this NVFP4 community quant, like
#     the Gemma 4 checkpoint in this folder, ships no fp8 KV scaling factors.
#     Set KV_CACHE_DTYPE=fp8 to roughly double the KV pool for more concurrency
#     or longer context; the launcher adds --calculate-kv-scales automatically
#     in that case so scales are computed on the fly instead of defaulting to
#     scale=1.0 (fp8 overflow / accuracy risk).
#   - max-num-seqs = 4, max-num-batched-tokens = 8192: the exact concurrency /
#     prefill-chunk pair measured working on a single Spark for this model.
#   - --distributed-executor-backend mp: required for this model/image
#     combination on Spark per the validated forum deployment.
#   - --tensor-parallel-size 1: single GB10 GPU.
#   - torch.compile cache is persisted (mounted) so the compile is paid once.
#
# ----------------------------------------------------------------------------
# Image note: the default ghcr.io/spark-arena/dgx-vllm-eugr-nightly image is the
# patched DGX Spark build; its ENTRYPOINT is NOT `vllm serve`, so this script
# prepends `vllm serve` inside the docker run command.
#
# Known issue (fixed upstream, verify if you hit it): early copies of the
# unsloth/Qwen3.8-27B-NVFP4 tokenizer silently truncated prompts at 2048
# tokens. If long-context requests come back truncated, re-pull the checkpoint
# and check tokenizer_config.json for "truncation": null.

set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
MODEL="${MODEL:-unsloth/Qwen3.8-27B-NVFP4}"
SERVED_NAME="${SERVED_NAME:-$MODEL}"   # canonical HF id so clients use it in the model field without remapping
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
CONTAINER_NAME="${CONTAINER_NAME:-vllm-qwen38}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
# vLLM's torch.compile cache lives at /root/.cache/vllm inside the container;
# persisting it across restarts skips the compile on every boot.
VLLM_CACHE="${VLLM_CACHE:-$HOME/.cache/vllm}"
# Explicit --shm-size cap over --ipc=host. On the Spark's unified memory this
# tmpfs is a lazy cap, not a reservation (single GB10 = no cross-GPU NCCL
# transfer, so actual /dev/shm use is small). Set SHM_SIZE="" to fall back to
# --ipc=host.
SHM_SIZE="${SHM_SIZE:-16g}"

# Serving knobs tuned for Spark's unified-memory / small-batch profile (see the
# Design decisions header for the rationale behind each default).
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.45}"                  # ~58 GB of the 128 GB pool — leaves room for a 2nd model side-by-side
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"               # native context; fits inside the 0.45 fraction as measured
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"                      # measured-working concurrency for this model on Spark
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"  # measured-working prefill chunk size
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"               # auto = full precision; set fp8 for a larger KV pool
NUM_SPEC_TOKENS="${NUM_SPEC_TOKENS:-5}"                # MTP block depth measured working on Spark
SKIP_PRESTAGE="${SKIP_PRESTAGE:-0}"                    # set to 1 to skip weight pre-staging

# ---- Agentic flags ----------------------------------------------------------
# Agentic serving (tool calls + reasoning) is ON by default:
#   --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3
# Qwen3.8 uses the model's bundled chat template (no --chat-template override
# needed). qwen3_coder is vLLM's documented parser for this model family; the
# DGX Spark forum deployment instead used qwen3_xml successfully — if tool
# calls come back unparsed, try TOOL_PARSER=qwen3_xml.
#
# To DISABLE agentic flags entirely:  AGENTIC=0 ./serve-qwen38-27b-mtp.sh
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

# KV cache dtype: only pass --calculate-kv-scales alongside fp8, matching this
# checkpoint's lack of shipped KV scaling factors (see Design decisions above).
KV_FLAGS=(--kv-cache-dtype "$KV_CACHE_DTYPE")
if [[ "$KV_CACHE_DTYPE" == "fp8" ]]; then
  KV_FLAGS+=(--calculate-kv-scales)
fi

# ---- Pre-flight -------------------------------------------------------------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "WARNING: HF_TOKEN is not set. Gated/private weights will fail to download." >&2
  echo "         export HF_TOKEN=hf_xxx   (then re-run)" >&2
fi

mkdir -p "$HF_CACHE" "$VLLM_CACHE"

# ---- Pre-stage weights ------------------------------------------------------
# "Download once, mount everywhere": fetch the NVFP4 checkpoint into the
# host-mounted HF cache BEFORE starting the server, so the first `vllm serve`
# boot is a load, not a download. Runs inside the SAME image vLLM serves from,
# so huggingface_hub versions match. Idempotent: cached files are skipped.
# Skip entirely with SKIP_PRESTAGE=1.
if [[ "$SKIP_PRESTAGE" != "1" ]]; then
  echo "Pre-staging $MODEL into $HF_CACHE ..."
  docker run --rm \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -e MODEL="$MODEL" \
    -v "${HF_CACHE}:/root/.cache/huggingface" \
    --entrypoint bash \
    "$IMAGE" \
    -c 'if command -v hf >/dev/null 2>&1; then hf download "$MODEL"; else huggingface-cli download "$MODEL"; fi'
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

echo "Starting vLLM container '$CONTAINER_NAME' serving $MODEL (MTP, ${NUM_SPEC_TOKENS} spec tokens) ..."
if [[ ${#AGENTIC_FLAGS[@]} -gt 0 ]]; then
  echo "Agentic flags: ${AGENTIC_FLAGS[*]}"
else
  echo "Agentic flags: none (disabled via AGENTIC=0)"
fi

# Shared-memory: explicit --shm-size cap or --ipc=host.
IPC_FLAGS=()
if [[ -n "$SHM_SIZE" ]]; then
  IPC_FLAGS=(--shm-size="$SHM_SIZE")
else
  IPC_FLAGS=(--ipc=host)
fi

# NOTE: the spark-arena image's ENTRYPOINT is NOT `vllm serve`, so we prepend it
# explicitly below.
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
    --tensor-parallel-size 1 \
    --distributed-executor-backend mp \
    --gpu-memory-utilization "$GPU_MEM_UTIL" \
    --max-model-len "$MAX_MODEL_LEN" \
    --max-num-seqs "$MAX_NUM_SEQS" \
    --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
    "${KV_FLAGS[@]}" \
    --trust-remote-code \
    --enable-prefix-caching \
    --enable-chunked-prefill \
    --speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${NUM_SPEC_TOKENS}}" \
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
echo "Ready.    http://localhost:${PORT}/v1"
echo "Metrics:  http://localhost:${PORT}/metrics"
echo "Logs:     docker logs -f ${CONTAINER_NAME}"
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
