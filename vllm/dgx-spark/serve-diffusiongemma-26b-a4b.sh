#!/usr/bin/env bash
#
# serve-diffusiongemma-26b-a4b.sh
# Serve RedHatAI/diffusiongemma-26B-A4B-it-NVFP4 with vLLM on an NVIDIA DGX
# Spark (GB10, sm_121). Standalone launcher following the same pattern as
# run-gemma4-26b-a4b-spark.sh.
#
# Workflow:
#   1. Pre-stage weights once into a host-mounted HF cache ("download once,
#      mount everywhere"), so the serving boot is a load, not a download.
#   2. Launch the long-running OpenAI-compatible server, agentic-ready by default.
#   3. Stream load logs, wait for readiness, then warm the JIT before first use.
#
# Configured for: 64K context, agentic/tool-calling workloads, HALF the Spark's
# unified pool (GPU_MEM_UTIL=0.45) so a second vLLM instance can run alongside.
#
# Running two instances side by side:
#   - This script defaults to PORT=8001 so it can coexist with the gemma4
#     launcher's default 8000; CONTAINER_NAME (vllm-dgemma) likewise already
#     differs from the gemma4 launcher's vllm-gemma4.
#   - The NEIGHBOR must also cap its memory: run-gemma4-26b-a4b-spark.sh still
#     defaults to GPU_MEM_UTIL=0.85, so launch it with GPU_MEM_UTIL=0.45 (and
#     correspondingly reduced MAX_MODEL_LEN/MAX_NUM_SEQS) or the two instances
#     overcommit the 128GB pool. --gpu-memory-utilization is a per-process
#     fraction of TOTAL memory; vLLM does not coordinate across processes.
#
# ----------------------------------------------------------------------------
# DiffusionGemma-specific decisions (and why):
#   - VLLM_USE_V2_MODEL_RUNNER=1: diffusion decoding is only implemented in the
#     V2 model runner; without it the V1 runner rejects the architecture.
#   - --trust-remote-code: required for diffusiongemma's custom modelling code.
#   - --attention-backend TRITON_ATTN: diffusion decode denoises blocks
#     bidirectionally rather than token-by-token, which rules out the default
#     paged-attention backends; TRITON_ATTN supports it (and is what GB10's
#     heterogeneous head dims force on Gemma-family models anyway).
#   - --hf-overrides diffusion sampler: entropy_bound stops denoising a block
#     early once per-token entropy drops below 0.1, trading a fixed step count
#     for adaptive early exit.
#   - Thinking mode on by default for every chat request via
#     --default-chat-template-kwargs; clients can override per-request.
#   - Agentic parsers default to the Gemma 4 recipe's names: DiffusionGemma
#     shares Gemma 4's 26B-A4B architecture and reasoning-channel format, but
#     neither Google's developer guide nor the RedHatAI card documents vLLM
#     parser names for it. UNVERIFIED for this model: on first run, send a
#     request with a tool schema and confirm the response contains parsed
#     tool_calls (not inline text).
#   - The model's bundled chat template is used as-is (no --chat-template
#     override) so --default-chat-template-kwargs applies and clients can
#     override per-request; set CHAT_TEMPLATE=examples/tool_chat_template_gemma4.jinja
#     only if the bundled template's tool formatting turns out broken.

set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
MODEL="${MODEL:-RedHatAI/diffusiongemma-26B-A4B-it-NVFP4}"
SERVED_NAME="${SERVED_NAME:-$MODEL}"   # default: clients use the full model path as the id
IMAGE="${IMAGE:-vllm/vllm-openai:gemma}"
PORT="${PORT:-8001}"  # 8001 so the gemma4 launcher (8000) can run alongside
# Host interface to publish the port on. 0.0.0.0 = reachable from other machines
# on the network (default). Set to 127.0.0.1 to restrict to this host only.
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
# API key for request auth. If not provided, a random one is generated so the
# endpoint is never unauthenticated by default. The key is printed at the end;
# clients send it as: Authorization: Bearer <key>
# Note: a new key is generated on each run unless you pass API_KEY explicitly,
# so pin API_KEY=... if you want it stable across restarts.
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
CONTAINER_NAME="${CONTAINER_NAME:-vllm-dgemma}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
# vLLM's torch.compile cache lives at /root/.cache/vllm inside the container.
# Persisting it across restarts skips the Dynamo+Inductor compile on every boot
# (the compiled graph is keyed to the model/flags/GPU, so it's reused).
VLLM_CACHE="${VLLM_CACHE:-$HOME/.cache/vllm}"

# Serving knobs sized for HALF the unified pool, so two vLLM instances can run
# side by side on one Spark. Budget at 0.45: ~57.6 GiB total for this instance;
# weights take ~18 GiB, leaving a ~35 GiB KV pool. Full-precision KV runs
# ~240 KiB/token here, so that pool holds ~150K tokens — two full 64K-context
# sequences fit with headroom (128K context would fit only ONE sequence).
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.45}"   # fraction of the 128GB unified pool; 0.45 leaves room for a second instance
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"   # 64K context; 2 full-context seqs fit the reduced KV pool
MAX_NUM_SEQS="${MAX_NUM_SEQS:-2}"      # 2 x 64K = ~128K KV tokens vs ~150K available — no preemption thrash
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"  # prefill chunk size; halved with concurrency so a long prefill doesn't starve the other stream
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"
# Safetensors load strategy (a `vllm serve` engine arg, applied at weight LOAD
# time). unset/empty = lazy mmap (best for Spark's local NVMe); 'prefetch' or
# 'eager' help on network/high-latency storage (NFS/Lustre).
LOAD_STRATEGY="${LOAD_STRATEGY:-}"

# ---- Agentic flags ----------------------------------------------------------
# Agentic serving (tool calls + reasoning) is ON by default, borrowing the
# parser names from vLLM's official Gemma 4 recipe (see header for the caveat —
# unverified for DiffusionGemma; check tool_calls parsing on first run).
#
# To DISABLE agentic flags entirely:  AGENTIC=0 ./serve-diffusiongemma-26b-a4b.sh
# To override a parser:               TOOL_PARSER=... REASONING_PARSER=... ./serve-...
AGENTIC="${AGENTIC:-1}"                       # 1 = enable tool/reasoning parsing
TOOL_PARSER="${TOOL_PARSER:-gemma4}"          # per vLLM Gemma 4 recipe
REASONING_PARSER="${REASONING_PARSER:-gemma4}" # per vLLM Gemma 4 recipe
# Default empty: use the model's bundled chat template (see header).
CHAT_TEMPLATE="${CHAT_TEMPLATE:-}"

# Build the optional flag list.
AGENTIC_FLAGS=()
if [[ "$AGENTIC" != "0" ]]; then
  if [[ -n "$TOOL_PARSER" ]]; then
    AGENTIC_FLAGS+=(--enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER")
  fi
  if [[ -n "$REASONING_PARSER" ]]; then
    AGENTIC_FLAGS+=(--reasoning-parser "$REASONING_PARSER")
  fi
  if [[ -n "$CHAT_TEMPLATE" ]]; then
    AGENTIC_FLAGS+=(--chat-template "$CHAT_TEMPLATE")
  fi
fi

# Optional serving flags (auth, load strategy, etc.).
SERVE_FLAGS=()
if [[ -n "$API_KEY" ]]; then
  SERVE_FLAGS+=(--api-key "$API_KEY")
fi
if [[ -n "$LOAD_STRATEGY" ]]; then
  SERVE_FLAGS+=(--safetensors-load-strategy "$LOAD_STRATEGY")
fi

# ---- Pre-flight -------------------------------------------------------------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "WARNING: HF_TOKEN is not set. Gated/private weights will fail to download." >&2
  echo "         export HF_TOKEN=hf_xxx   (then re-run)" >&2
fi

mkdir -p "$HF_CACHE" "$VLLM_CACHE"

# ---- Pre-stage weights ------------------------------------------------------
# "Download once, mount everywhere": fetch the weights into the host-mounted HF
# cache BEFORE starting the long-running server, so the first `vllm serve` boot
# doesn't also perform a large download. The same cache is then mounted into the
# serving container below, and reused across restarts.
#
# This runs the download inside the SAME image vLLM serves from, so the
# huggingface_hub version matches. It is idempotent: already-cached files are
# skipped, so re-running is cheap.
#
# Skip with:  SKIP_PRESTAGE=1 ./serve-diffusiongemma-26b-a4b.sh
SKIP_PRESTAGE="${SKIP_PRESTAGE:-0}"
if [[ "$SKIP_PRESTAGE" != "1" ]]; then
  echo "Pre-staging weights for $MODEL into $HF_CACHE ..."
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
echo "Starting vLLM container '$CONTAINER_NAME' serving $MODEL ..."
if [[ ${#AGENTIC_FLAGS[@]} -gt 0 ]]; then
  echo "Agentic flags: ${AGENTIC_FLAGS[*]}"
else
  echo "Agentic flags: none (disabled via AGENTIC=0)"
fi

# Docker run flags:
#   -d                      run detached (background); we tail logs separately below
#   --name                  stable container name so restart/stop/logs are predictable
#   --ipc=host              share host IPC namespace -> larger /dev/shm. vLLM uses
#                           shared memory for tensor/IPC transfer; the default 64MB
#                           is too small and causes crashes, so host IPC is required.
#   --restart unless-stopped  auto-restart on crash or host reboot, but stay down if
#                           you explicitly `docker stop` it.
#   --gpus all              expose the GB10 GPU to the container (NVIDIA runtime).
#   -p BIND_ADDR:PORT:8000  publish the in-container port 8000 on the host.
#   -e VLLM_USE_V2_MODEL_RUNNER=1  diffusion decoding requires the V2 model runner.
#   -v HF_CACHE / VLLM_CACHE  weight cache + torch.compile cache reused across restarts.
#
# vllm serve flags:
#   NOTE: the image's ENTRYPOINT is already `vllm serve`, so we pass ONLY the
#         model and flags after "$IMAGE" — do NOT prepend `vllm serve` here.
#   --trust-remote-code     required for diffusiongemma's custom modelling code.
#   --attention-backend     TRITON_ATTN — the only backend supporting diffusion's
#                           bidirectional block denoising (see header).
#   --hf-overrides          diffusion sampler config (read from hf config
#                           overrides, not CLI flags): entropy_bound early exit.
#   --default-chat-template-kwargs  thinking mode on by default for every chat
#                           request unless the client overrides it per-request.
#   --enable-prefix-caching / --enable-chunked-prefill  on by default in V1;
#                           explicit here to document intent.
docker run -d --name "$CONTAINER_NAME" --ipc=host --restart unless-stopped \
  --gpus all -p "${BIND_ADDR}:${PORT}:8000" \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -e VLLM_USE_V2_MODEL_RUNNER=1 \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  -v "${VLLM_CACHE}:/root/.cache/vllm" \
  "$IMAGE" \
  "$MODEL" \
    --served-model-name "$SERVED_NAME" \
    --trust-remote-code \
    --attention-backend TRITON_ATTN \
    --hf-overrides '{"diffusion_sampler": "entropy_bound", "diffusion_entropy_bound": 0.1}' \
    --default-chat-template-kwargs '{"enable_thinking": true}' \
    --max-model-len "$MAX_MODEL_LEN" \
    --gpu-memory-utilization "$GPU_MEM_UTIL" \
    --max-num-seqs "$MAX_NUM_SEQS" \
    --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
    --kv-cache-dtype "$KV_CACHE_DTYPE" \
    --enable-prefix-caching \
    --enable-chunked-prefill \
    ${SERVE_FLAGS[@]+"${SERVE_FLAGS[@]}"} \
    ${AGENTIC_FLAGS[@]+"${AGENTIC_FLAGS[@]}"}

# ---- Wait for readiness -----------------------------------------------------
# With weights pre-staged, this boot is the safetensor LOAD (several minutes),
# not the download. The first *request* additionally triggers JIT codegen.
AUTH_HEADER="Authorization: Bearer ${API_KEY}"
echo "Waiting for the server to come up (weight load can take several minutes)..."
echo "Streaming container logs below (Ctrl-C stops the script, not the container):"
echo "------------------------------------------------------------------------------"

# Tail the container logs in the background so weight-load progress is visible
# during the wait. We stop this tail once the endpoint responds.
docker logs -f "$CONTAINER_NAME" 2>&1 &
LOG_PID=$!
# Ensure the background tail is cleaned up if the script exits early.
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

until curl -sS -H "$AUTH_HEADER" "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; do
  # If the container died during load, stop waiting and surface the failure.
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    kill "$LOG_PID" 2>/dev/null || true
    echo "------------------------------------------------------------------------------"
    echo "ERROR: container '$CONTAINER_NAME' exited during startup. Full logs:" >&2
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 50 >&2
    exit 1
  fi
  sleep 5
done

# Endpoint is up; stop the live log tail.
kill "$LOG_PID" 2>/dev/null || true
trap - EXIT
echo "------------------------------------------------------------------------------"

READY_ID="$(curl -sS -H "$AUTH_HEADER" "http://localhost:${PORT}/v1/models" | jq -r '.data[0].id' 2>/dev/null || true)"
echo "Server is up. Reported model id: ${READY_ID:-<unknown>}"

# ---- Pre-warm the JIT -------------------------------------------------------
# Fire a tiny request so the first real user request doesn't eat cold-start JIT.
echo "Pre-warming JIT with a 3-token request..."
curl -sS "http://localhost:${PORT}/v1/chat/completions" \
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
  echo "  The endpoint requires the API key above. For untrusted networks, also"
  echo "  restrict the port with the host firewall — the key is not a substitute"
  echo "  for network access control."
fi
