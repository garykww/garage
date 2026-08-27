#!/usr/bin/env bash
#
# serve-qwen38-27b-vllm-tuned.sh
# Serve Qwen3.8-27B (NVFP4) on an NVIDIA DGX Spark (GB10, sm_121) via vLLM in
# Docker, carrying over the tuning from serve-qwen38-27b-sglang.sh.
#
# WHY THIS EXISTS, given serve-qwen38-27b-mtp.sh is already the vLLM script:
# that one is the conservative shared-box recipe (unsloth export, full-precision
# KV, gpu-memory-utilization 0.45, no GDN state-pool tuning). This one is the
# SGLang recipe's *measured* configuration expressed in vLLM flags — the
# RadixArk export with FP8 KV scales, GDN state sized deliberately, FlashInfer
# attention, CPU pinning, and the box claimed almost entirely. Run this when the
# Spark is yours alone; run the -mtp one when you are sharing it.
#
# ----------------------------------------------------------------------------
# PORT MAP — what carried over from the SGLang recipe, and what did not.
# Verified by probing `vllm serve --help=all` inside the image below
# (vLLM 0.22.1rc1.dev330), not from docs.
#
#   SGLang flag                        vLLM equivalent                    ported
#   ---------------------------------  ---------------------------------  ------
#   --attention-backend flashinfer     --attention-backend FLASHINFER     yes
#   --kv-cache-dtype fp8_e4m3          --kv-cache-dtype fp8               yes
#   --mamba-ssm-dtype bfloat16         --mamba-ssm-cache-dtype bfloat16   yes
#   --max-running-requests N           --max-num-seqs N                   yes
#   --mem-fraction-static F            --gpu-memory-utilization F         yes
#   --chunked-prefill-size N           --max-num-batched-tokens N         yes
#   EAGLE steps/topk/draft (MTP)       --speculative-config method=mtp    yes
#   --reasoning-parser / tool parser   same, + --enable-auto-tool-choice  yes
#   --cpuset-cpus (docker)             --cpuset-cpus (docker)             yes
#   (n/a)                              --mamba-cache-mode align           added
#   --mamba-full-memory-ratio 4.21     none                               NO
#   --max-mamba-cache-size N           none                               NO
#   --disable-prefill-cuda-graph       none                               NO
#   SPEC_MODE=dspark                   needs vLLM >= 0.25 + custom code   NO
#   YaRN via rope_parameters           --hf-overrides (no --rope-scaling) differs
#
# The two GDN pool flags are the notable loss. SGLang lets you pin the recurrent
# state pool directly (--max-mamba-cache-size = concurrency x S) and correct its
# bad default ratio. vLLM has no such knob: it derives the mamba state pool from
# max-num-seqs and takes the rest as KV. So the SGLang recipe's "pin the pool,
# then set concurrency" logic inverts here — you set MAX_NUM_SEQS and vLLM sizes
# the pool for you. --mamba-ssm-cache-dtype bfloat16 still halves the per-slot
# cost (78.4 MB vs 153.9 MB at fp32), which is the larger of the two levers.
#
# --mamba-cache-mode align has no SGLang counterpart but is REQUIRED on vLLM for
# GDN layers; the `all` mode is unsupported for this architecture.
#
# DSpark does not port. The drafter exists for vLLM (Doopeworld/
# Qwen3.8-27B-DSpark-vLLM, --speculative-config method=dspark, 7 tokens) but
# needs vLLM >= 0.25 plus a custom modeling file, and the Spark image here is
# 0.22. The script refuses SPEC_MODE=dspark rather than failing at load. Note
# also that upstream reports DSpark's adaptive-verification confidence head is
# inert on Qwen3.8 under vLLM, because GDN layers use GDNAttentionBackend — so
# even on a new enough build you get block drafting without adaptive verify.
#
# ----------------------------------------------------------------------------
# UNVERIFIED — read before trusting this on real traffic:
#   - Whether vLLM loads the RadixArk NVFP4 exports at all. The -mtp script in
#     this folder uses the unsloth export; these RadixArk ones were measured
#     under SGLang. The NVFP4 kernel path and the BF16-lm_head variant in
#     particular are unconfirmed on vLLM. If it fails at load, set
#     QUANT=unsloth to fall back to the export vLLM is known to serve.
#   - The GDN + MTP + FP8-KV combination on vLLM. Each piece is supported; the
#     three together on this build are not something this script has proven.
#     Upstream has open issues on mamba prefix-caching interacting badly with
#     MTP on other hybrid models.
#   - Throughput. Every number in the SGLang README section was measured under
#     SGLang. None of it transfers. Benchmark before believing anything.
#
# ----------------------------------------------------------------------------
# Port note: defaults to 8000, same as the other scripts here. Only one can hold
# it — stop the others or pass PORT=8888.

set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
QUANT="${QUANT:-nvfp4}"
case "$QUANT" in
  nvfp4)     MODEL="RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead" ;;  # SGLang recipe's default
  nvfp4-fp4) MODEL="RadixArk/Qwen3.8-27B-NVFP4" ;;
  unsloth)   MODEL="unsloth/Qwen3.8-27B-NVFP4" ;;               # the export -mtp uses; known-good on vLLM
  fp8)       MODEL="Qwen/Qwen3.8-27B-FP8" ;;
  bf16)      MODEL="Qwen/Qwen3.8-27B" ;;
  *) echo "ERROR: unknown QUANT '$QUANT' (use nvfp4|nvfp4-fp4|unsloth|fp8|bf16)" >&2; exit 1 ;;
esac
MODEL="${MODEL_OVERRIDE:-$MODEL}"
SERVED_NAME="${SERVED_NAME:-$MODEL}"
IMAGE="${IMAGE:-ghcr.io/spark-arena/dgx-vllm-eugr-nightly}"
PORT="${PORT:-8000}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
CONTAINER_NAME="${CONTAINER_NAME:-vllm-qwen38-tuned}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
VLLM_CACHE="${VLLM_CACHE:-$HOME/.cache/vllm}"
SHM_SIZE="${SHM_SIZE:-32g}"
CPUSET="${CPUSET:-5-9,15-19}"        # GB10 Cortex-X5 cores; "" disables pinning
SKIP_PRESTAGE="${SKIP_PRESTAGE:-0}"

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

SPEC_MODE="${SPEC_MODE:-mtp}"                        # mtp | none  (dspark unsupported here)
SPEC_TOKENS="${SPEC_TOKENS:-3}"                      # SGLang SPEC_STEPS=3 peak maps to this
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"             # 262144 .. 1000000
YARN="${YARN:-0}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-10}"                   # SGLang MAX_CONCURRENT_REQUESTS
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"   # SGLang CHUNKED_PREFILL
ATTENTION_BACKEND="${ATTENTION_BACKEND:-FLASHINFER}" # TRITON_ATTN is the fallback
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"
MAMBA_SSM_CACHE_DTYPE="${MAMBA_SSM_CACHE_DTYPE:-bfloat16}"
MAMBA_CACHE_MODE="${MAMBA_CACHE_MODE:-align}"        # required for GDN on vLLM
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.95}"                 # SGLang MEM_FRACTION_STATIC (MTP default)
REASONING_PARSER="${REASONING_PARSER:-qwen3}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
AGENTIC="${AGENTIC:-1}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# ---- Validate ---------------------------------------------------------------
case "$SPEC_MODE" in
  mtp|none) : ;;
  dspark)
    echo "ERROR: SPEC_MODE=dspark is not supported by this recipe." >&2
    echo "       vLLM DSpark needs >= 0.25 plus a custom modeling file; the Spark" >&2
    echo "       image here is 0.22.x. Use serve-qwen38-27b-sglang.sh for DSpark," >&2
    echo "       or SPEC_MODE=mtp here." >&2
    exit 1 ;;
  *) echo "ERROR: SPEC_MODE must be mtp or none (got '$SPEC_MODE')" >&2; exit 1 ;;
esac

if (( MAX_MODEL_LEN < 262144 || MAX_MODEL_LEN > 1000000 )); then
  echo "ERROR: MAX_MODEL_LEN must be 262144..1000000 (got $MAX_MODEL_LEN)" >&2
  exit 1
fi

NEED_YARN=0
if (( MAX_MODEL_LEN > 262144 )); then
  if [[ "$YARN" == "1" || "$MAX_MODEL_LEN" == "1000000" ]]; then
    NEED_YARN=1
  else
    echo "ERROR: MAX_MODEL_LEN > 262144 needs YARN=1 (rope scaling beyond native)." >&2
    exit 1
  fi
fi

# ---- Assemble vLLM flags ----------------------------------------------------
SERVE_FLAGS=(
  "$MODEL"
  --served-model-name "$SERVED_NAME"
  --tensor-parallel-size 1
  --distributed-executor-backend mp
  --gpu-memory-utilization "$GPU_MEM_UTIL"
  --max-model-len "$MAX_MODEL_LEN"
  --max-num-seqs "$MAX_NUM_SEQS"
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --attention-backend "$ATTENTION_BACKEND"
  --kv-cache-dtype "$KV_CACHE_DTYPE"
  --mamba-ssm-cache-dtype "$MAMBA_SSM_CACHE_DTYPE"
  --mamba-cache-mode "$MAMBA_CACHE_MODE"
  --trust-remote-code
  --enable-prefix-caching
  --enable-chunked-prefill
  --api-key "$API_KEY"
)

# The RadixArk NVFP4 exports declare FP8 KV and ship calibration scales, so fp8
# needs no on-the-fly computation. The unsloth/fp8/bf16 paths do not ship scales
# — compute them during prefill rather than silently defaulting to scale=1.0.
if [[ "$KV_CACHE_DTYPE" == "fp8" && "$QUANT" != "nvfp4" && "$QUANT" != "nvfp4-fp4" ]]; then
  SERVE_FLAGS+=(--calculate-kv-scales)
fi

if [[ "$SPEC_MODE" == "mtp" ]]; then
  SERVE_FLAGS+=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${SPEC_TOKENS}}")
fi

# vLLM in this image exposes no --rope-scaling; YaRN goes through --hf-overrides.
if (( NEED_YARN )); then
  SERVE_FLAGS+=(--hf-overrides "{\"rope_scaling\":{\"rope_type\":\"yarn\",\"factor\":4.0,\"original_max_position_embeddings\":262144}}")
fi

if [[ "$AGENTIC" != "0" ]]; then
  [[ -n "$TOOL_PARSER" ]] && SERVE_FLAGS+=(--enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER")
  [[ -n "$REASONING_PARSER" ]] && SERVE_FLAGS+=(--reasoning-parser "$REASONING_PARSER")
fi

# shellcheck disable=SC2206  # deliberate word-splitting: EXTRA_ARGS is a flag string
[[ -n "$EXTRA_ARGS" ]] && SERVE_FLAGS+=($EXTRA_ARGS)

# ---- Pre-flight -------------------------------------------------------------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "WARNING: HF_TOKEN is not set. Gated/private weights will fail to download." >&2
fi
mkdir -p "$HF_CACHE" "$VLLM_CACHE"

# ---- Pre-stage weights ------------------------------------------------------
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
  echo "Skipping pre-stage (SKIP_PRESTAGE=1)."
fi

# ---- Launch -----------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Removing existing container '$CONTAINER_NAME'..."
  docker rm -f "$CONTAINER_NAME"
fi

echo "Starting vLLM container '$CONTAINER_NAME' serving $MODEL ..."
echo "  spec=$SPEC_MODE  attn=$ATTENTION_BACKEND  kv=$KV_CACHE_DTYPE  gmu=$GPU_MEM_UTIL  seqs=$MAX_NUM_SEQS"
(( NEED_YARN )) && echo "  YaRN rope scaling to $MAX_MODEL_LEN via --hf-overrides"

DOCKER_FLAGS=(--shm-size="$SHM_SIZE")
[[ -n "$CPUSET" ]] && DOCKER_FLAGS+=(--cpuset-cpus "$CPUSET")

docker run -d \
  --name "$CONTAINER_NAME" \
  "${DOCKER_FLAGS[@]}" \
  --restart unless-stopped \
  --gpus all \
  -p "${BIND_ADDR}:${PORT}:8000" \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  -v "${VLLM_CACHE}:/root/.cache/vllm" \
  "$IMAGE" \
  vllm serve "${SERVE_FLAGS[@]}"

# ---- Wait for readiness -----------------------------------------------------
AUTH_HEADER="Authorization: Bearer ${API_KEY}"
echo "Waiting for the server (weight load can take several minutes)..."
echo "Streaming container logs (Ctrl-C stops the script, not the container):"
echo "------------------------------------------------------------------------------"

docker logs -f "$CONTAINER_NAME" 2>&1 &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

until curl -sf -H "$AUTH_HEADER" "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    kill "$LOG_PID" 2>/dev/null || true
    echo "------------------------------------------------------------------------------"
    echo "ERROR: container '$CONTAINER_NAME' exited during startup. Last 50 lines:" >&2
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 50 >&2
    echo >&2
    echo "If this failed loading NVFP4 weights, vLLM may not support the RadixArk" >&2
    echo "export — retry with QUANT=unsloth (the export serve-qwen38-27b-mtp.sh uses)." >&2
    exit 1
  fi
  sleep 5
done

kill "$LOG_PID" 2>/dev/null || true
trap - EXIT
echo "------------------------------------------------------------------------------"

READY_ID="$(curl -sf -H "$AUTH_HEADER" "http://localhost:${PORT}/v1/models" | jq -r '.data[0].id' 2>/dev/null || true)"
echo "Server is up. Reported model id: ${READY_ID:-<unknown>}"

echo "Warming up..."
curl -sf "http://localhost:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d "{\"model\":\"${SERVED_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" \
  >/dev/null && echo "Warm-up done." || echo "Warm-up failed (server may still be loading)."

echo
echo "Ready.    http://localhost:${PORT}/v1"
echo "Metrics:  http://localhost:${PORT}/metrics"
echo "Logs:     docker logs -f ${CONTAINER_NAME}"
echo
if [[ "$API_KEY_GENERATED" == "1" ]]; then
  echo "API key (auto-generated this run): ${API_KEY}"
else
  echo "API key: (provided via API_KEY)"
fi
echo "  Clients must send:  Authorization: Bearer ${API_KEY}"
