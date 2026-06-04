#!/usr/bin/env bash
#
# run-gemma4-spark.sh
# Serve nvidia/Gemma-4-26B-A4B-NVFP4 with vLLM on an NVIDIA DGX Spark (GB10, sm_121).
#
# Adapted from the vLLM DGX Spark recipe:
#   https://vllm.ai/blog/2026-06-01-vllm-dgx-spark
# and from vLLM's official Gemma 4 usage guide (parser + chat-template names):
#   https://docs.vllm.ai/projects/recipes/en/latest/Google/Gemma4.html
#
# Workflow:
#   1. Pre-stage weights once into a host-mounted HF cache ("download once, mount
#      everywhere"), so the serving boot is a load, not a download.
#   2. Launch the long-running OpenAI-compatible server, agentic-ready by default.
#   3. Stream load logs, wait for readiness, then warm the JIT before first use.
#
# Configured for: 128K context, agentic/tool-calling workloads, single Spark.
#
# ----------------------------------------------------------------------------
# Design decisions (and why):
#   - Agentic ON by default: --enable-auto-tool-choice + gemma4 tool/reasoning
#     parsers + the gemma4 chat template, per vLLM's official Gemma 4 recipe.
#     Gemma 4's tool-call format is custom (non-JSON), so parser AND template
#     must match or tool calling breaks under agent clients (e.g. Claude Code).
#   - Authenticated by default: a random API key is generated if none is given,
#     so the endpoint is never open. BIND_ADDR controls network reachability.
#   - 128K context (--max-model-len 131072) for long agent histories + tool
#     schemas. See the KV-capacity note below for the concurrency trade-off.
#   - max-num-seqs = 4: a CEILING, not a reservation. Spark's bandwidth taxes
#     >4 decode streams (TTFT spikes), and 4 fits 128K KV without preemption
#     thrash. vLLM pages/preempts gracefully above this, so it never OOMs.
#   - max-num-batched-tokens = 16384: prefill chunk size, decoupled from both
#     context length (chunked prefill splits long prompts) and max-num-seqs.
#     Sits near Spark's SM-bound prefill plateau; bigger buys little here.
#   - kv-cache-dtype = auto (full precision): this checkpoint auto-selects fp8
#     but ships NO KV scaling factors (falls back to scale=1.0), which hurts
#     predictability on long agent loops. We have ample KV headroom, so fp8's
#     memory saving isn't needed. SEE "verify after restart" below.
#   - torch.compile cache is persisted (mounted) so the ~35s compile is paid
#     once, not on every restart.
#
# ----------------------------------------------------------------------------
# Findings from the 2026-06-04 startup logs (this exact model + image):
#   - Architecture resolved: Gemma4ForConditionalGeneration; quant modelopt_fp4;
#     MoE backend VLLM_CUTLASS; attention forced to TRITON_ATTN (heterogeneous
#     head dims). Gemma 4 is MULTIMODAL (image/video encoder) — the text-only
#     warm-up below does not warm the vision path.
#   - Weights: 17.50 GiB checkpoint, ~112s to load; model used 17.98 GiB. Local
#     EXT4 storage, so vLLM auto-prefetch stays off (LOAD_STRATEGY left empty).
#   - KV cache (measured under fp8): 78.82 GiB pool, 688,704 tokens. The pool's
#     byte size is fixed by --gpu-memory-utilization; per-request context length
#     and KV dtype determine how many sequences fit. At 128K/request that pool
#     holds ~5 full-context sequences under fp8, ~2-3 under full precision —
#     hence max-num-seqs=4 and the dtype caveat below.
#   - torch.compile took ~35s (Dynamo 4.7s + Inductor 23.3s) and was written to
#     /root/.cache/vllm — now persisted via the mount so restarts skip it.
#   - The model's generation_config.json sets temperature=1.0, top_k=64,
#     top_p=0.95 (creative defaults). For reliable tool calls, have CLIENTS pass
#     a lower temperature per-request, or relaunch with --generation-config vllm.
#
# Verify after the next restart (logs):
#   - "Using ... data type to store kv cache" — confirms whether KV_CACHE_DTYPE
#     auto actually forced full precision or the checkpoint still selects fp8.
#   - "Maximum concurrency for 131,072 tokens" — confirms how many 128K sequences
#     fit; if below your need, raise GPU_MEM_UTIL or accept KV_CACHE_DTYPE=fp8.
#
# Reproducibility:
#   - cu130-nightly is a COMPATIBILITY TRACK, not a reproducible pin. For a real
#     deployment, replace it with the exact release tag / commit-nightly tag /
#     image digest you validated, and record that in your runbook. (A dedicated
#     vllm/vllm-openai:gemma4-unified-* tag family also exists for this model.)

set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
MODEL="${MODEL:-nvidia/Gemma-4-26B-A4B-NVFP4}"
SERVED_NAME="${SERVED_NAME:-$MODEL}"   # default: clients use the full model path as the id
IMAGE="${IMAGE:-vllm/vllm-openai:cu130-nightly}"  # also: vllm/vllm-openai:gemma4-unified-cu130 (model-specific)
PORT="${PORT:-8000}"
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
CONTAINER_NAME="${CONTAINER_NAME:-vllm-gemma4}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
# vLLM's torch.compile cache lives at /root/.cache/vllm inside the container.
# Persisting it across restarts skips the ~35s Dynamo+Inductor compile on every
# boot (the compiled graph is keyed to the model/flags/GPU, so it's reused).
VLLM_CACHE="${VLLM_CACHE:-$HOME/.cache/vllm}"

# Serving knobs tuned for Spark's unified-memory / small-batch profile.
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.85}"   # fraction of the 128GB unified pool for vLLM; raise if you need more 128K KV concurrency, lower to free RAM for the OS
MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"  # 128K context
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"      # Spark: >4 decode streams taxes bandwidth + TTFT; also fits 128K KV better
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-16384}"  # prefill chunk size; near Spark's SM-bound prefill plateau, well above the 4-seq decode floor
# KV cache dtype. This model defaults to fp8_e4m3, but its checkpoint ships no
# KV scaling factors, so vLLM falls back to scale=1.0 — which can hurt accuracy
# and output predictability (bad for long agent loops). Default below requests
# full-precision KV. NOTE: at 128K context, full precision roughly halves how
# many sequences fit (~2-3 vs ~5 under fp8); with max-num-seqs=4 that's usually
# fine. Set KV_CACHE_DTYPE=fp8 if you need the extra 128K concurrency/memory.
# (Verify from the restart log which dtype actually took — see header.)
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"
# Safetensors load strategy (a `vllm serve` engine arg, applied at weight LOAD
# time on the serving container — not at download time).
#   unset/empty (default): vLLM uses lazy mmap, and auto-enables prefetch if it
#                          detects NFS. Best for local NVMe like Spark's.
#   prefetch : read checkpoint files into the OS page cache before workers load
#              them. Helps on network/high-latency storage (NFS/Lustre). On local
#              Spark NVMe the gain is usually small, and the page cache competes
#              with weights+KV in the same 128GB unified pool.
#   eager    : read the whole file into CPU RAM upfront (most RAM, best for NFS).
# Enable with:  LOAD_STRATEGY=prefetch ./run-gemma4-spark.sh
LOAD_STRATEGY="${LOAD_STRATEGY:-}"

# ---- Agentic flags ----------------------------------------------------------
# Agentic serving (tool calls + reasoning) is ON by default, using the parser
# names from vLLM's official Gemma 4 recipe:
#   --enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4
#   --chat-template examples/tool_chat_template_gemma4.jinja
#
# Gemma 4 uses a custom (non-JSON) tool-call serialization, so the gemma4 parser
# AND the matching chat template must agree — omitting the template is a known
# cause of broken tool calling under agent clients like Claude Code.
#
# To DISABLE agentic flags entirely:  AGENTIC=0 ./run-gemma4-spark.sh
# To override a parser:               TOOL_PARSER=... REASONING_PARSER=... ./run-...
AGENTIC="${AGENTIC:-1}"                       # 1 = enable tool/reasoning parsing
TOOL_PARSER="${TOOL_PARSER:-gemma4}"          # per vLLM Gemma 4 recipe
REASONING_PARSER="${REASONING_PARSER:-gemma4}" # per vLLM Gemma 4 recipe
# Chat template shipped inside the official vLLM container image.
CHAT_TEMPLATE="${CHAT_TEMPLATE:-examples/tool_chat_template_gemma4.jinja}"
#
# Notes for agentic serving:
#   - Automatic prefix caching is ON by default in vLLM V1 (no flag needed) and
#     is the biggest win: the system prompt + tool schemas are a long shared
#     prefix repeated every turn, so cache hits cut TTFT sharply.
#   - Structured/JSON output uses vLLM's default guided-decoding backend
#     (xgrammar in recent builds). Leave it unless you hit grammar issues.
#   - KV cache dtype is set via KV_CACHE_DTYPE (default 'auto' = full precision)
#     rather than fp8, since this model's checkpoint has no KV scaling factors
#     and fp8 would hurt predictability across a long agent loop.

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
# Skip with:  SKIP_PRESTAGE=1 ./run-gemma4-spark.sh
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
#                           you explicitly `docker stop` it (so it survives a reboot
#                           but respects a deliberate shutdown).
#   --gpus all              expose the GB10 GPU to the container (NVIDIA runtime).
#   -p BIND_ADDR:PORT:8000  publish the in-container port 8000 on the host. BIND_ADDR
#                           controls reachability: 0.0.0.0 = other machines, 127.0.0.1
#                           = local only.
#   -e HF_TOKEN             pass the HF token for gated/private weight access.
#   -v HF_CACHE:/root/.cache/huggingface  mount the host weight cache ("download once,
#                           mount everywhere") so weights are reused across restarts.
#   -v VLLM_CACHE:/root/.cache/vllm  persist vLLM's torch.compile cache so the
#                           ~35s graph compile is skipped on subsequent restarts.
#
# vllm serve flags:
#   NOTE: the image's ENTRYPOINT is already `vllm serve`, so we pass ONLY the
#         model and flags after "$IMAGE" — do NOT prepend `vllm serve` here or
#         you get "unrecognized arguments: serve <model>".
#   --served-model-name     the id clients use in the "model" field. Defaults to
#                           the full MODEL path; override SERVED_NAME for a short alias.
#   --max-model-len         max context (prompt+output) per request; drives KV-cache
#                           sizing. 128K for long agent histories + tool schemas.
#   --gpu-memory-utilization  fraction of the unified pool vLLM may claim. On Spark
#                           CPU/GPU/OS/KV share one 128GB pool, so we leave headroom.
#   --max-num-seqs          max concurrent sequences. Spark favors small-batch; this
#                           caps how many agent sessions run at once.
#   --max-num-batched-tokens  tokens processed per scheduler step = prefill chunk
#                           size. Smaller -> long prompts interleave with other
#                           sequences' decode, keeping TTFT fair under concurrency.
#   --kv-cache-dtype        KV cache precision. 'auto' (default here) = full
#                           precision; this model auto-selects fp8 otherwise but
#                           ships no KV scaling factors, hurting predictability.
#   --enable-prefix-caching   reuse KV blocks across requests sharing an opening
#                           prefix. Big win for agents: the system prompt + tool
#                           schemas repeat every turn. (On by default in V1; explicit
#                           here to document intent.)
#   --enable-chunked-prefill  split long prefills into chunks so a big prompt doesn't
#                           monopolize a step and spike everyone else's latency.
#                           (On by default in V1; explicit to document intent.)
#   SERVE_FLAGS             optional: --api-key for request auth, and
#                           --safetensors-load-strategy (see LOAD_STRATEGY above).
#   AGENTIC_FLAGS           optional: tool-call + reasoning parsers + chat template
#                           for Gemma 4 (see Agentic flags section above).
docker run -d --name "$CONTAINER_NAME" --ipc=host --restart unless-stopped \
  --gpus all -p "${BIND_ADDR}:${PORT}:8000" \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  -v "${VLLM_CACHE}:/root/.cache/vllm" \
  "$IMAGE" \
  "$MODEL" \
    --served-model-name "$SERVED_NAME" \
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
# not the download. The first *request* additionally triggers ~25s of JIT codegen.
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
