#!/usr/bin/env bash
#
# serve-qwen38-27b-sglang.sh
# Serve Qwen3.8-27B (NVFP4) on an NVIDIA DGX Spark (GB10, sm_121) via SGLang
# in Docker, with a choice of speculative-decoding drafters.
#
# This is the SGLang sibling of serve-qwen38-27b-mtp.sh (vLLM). Same box, same
# model family, different engine — SGLang is where the GB10-specific tuning
# lives (GDN state-pool sizing, FlashInfer attention, DSpark drafting), and it
# is measurably faster on code.
#
# Standalone launcher (everything in one file):
#   1. Pre-stage the NVFP4 target (and the DSpark drafter, if selected) into a
#      host-mounted HF cache.
#   2. Launch the long-running OpenAI-compatible server, agentic-ready.
#   3. Stream load logs, wait for readiness, then warm the model.
#
# ----------------------------------------------------------------------------
# Credit: the flag stack here follows MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark,
# which starts from the SGLang cookbook's DGX Spark cell and then pins each
# choice against on-device measurements. Their numbers, their box — see the
# README's SGLang section for the table and its caveats.
#
# ----------------------------------------------------------------------------
# Design decisions (and why):
#
#   - Checkpoint: RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead. NVFP4 W4A4 body with
#     a DENSE BF16 lm_head; the cookbook recipes were measured against this
#     export. QUANT=nvfp4-fp4 selects the packed-FP4-head twin (~22 GB vs
#     ~24 GB, and required if you want the quantized-head path). This is a
#     different checkpoint from the vLLM script's unsloth export — notably it
#     never had the 2048-token tokenizer truncation bug.
#
#   - --attention-backend flashinfer is REQUIRED on sm_120/sm_121. The
#     cookbook's trtllm_mha is SM100-only and will not run on GB10. If
#     speculative decode errors at boot, ATTENTION_BACKEND=triton is the
#     documented fallback.
#
#   - --kv-cache-dtype fp8_e4m3, explicitly. The NVFP4 checkpoint declares
#     FP8 KV and ships calibration scales, so `auto` would apply it anyway;
#     the explicit flag keeps FP8 KV if you switch QUANT to bf16/fp8 (dynamic
#     scales then). ~32.8 KB/token — a full 1M-token sequence is ~33 GB of KV.
#     Note this differs from the vLLM script in this folder, which runs
#     full-precision KV because the unsloth export ships no KV scales.
#
#   - GDN state pool. Qwen3.8-27B is a hybrid: 48 linear-attention (gated delta
#     net) layers + 16 full-attention layers. The recurrent state lives in a
#     separate pool that SGLang sizes badly by default:
#       * --mamba-full-memory-ratio 4.21 replaces the 0.9 default, which
#         over-provisions the KV pool and silently clamps concurrency.
#       * --max-mamba-cache-size = concurrency x S is the authoritative pin.
#         S=4 for extra_buffer_lazy + the overlap scheduler; S=3 when
#         MAMBA_SKIP_DECODE_LOCK=1 frees a resident slot per request.
#         Speculative verify states are a SEPARATE buffer — folding draft
#         tokens into this number over-provisions the pool 2x.
#       * --mamba-ssm-dtype bfloat16 keeps a slot at 78.4 MB; the fp32 default
#         is 153.9 MB/slot and would double the pool for ~3% less throughput.
#       * --max-running-requests pins the scheduler cap, which speculative
#         decoding otherwise resets to 48 behind your back.
#
#   - Speculative decoding, SPEC_MODE=mtp|dspark:
#       * mtp (default): the checkpoint's own in-checkpoint MTP head via
#         EAGLE 3 steps / topk 1 / 4 draft tokens. No second download. Upstream's
#         step sweep peaked exactly here (2 -> 12.8, 3 -> 17.2, 4 -> 16.8,
#         5 -> 16.3, 6 -> 15.8 tok/s). topk=1 is chain drafting, which requires
#         SPEC_DRAFT = SPEC_STEPS + 1; the script enforces that.
#       * dspark: the cookbook's trained drafter, a separate ~2.7 GB checkpoint,
#         block size 7 with an 8-token verify window. Much faster on code
#         (~1.5x on upstream's LRUCache probe) and slower on long prose.
#     DFlash2 is a third option upstream supports, but it needs a derived image
#     built from their patch/ tree — out of scope here; use their repo for it.
#
#   - --mem-fraction-static defaults per mode: 0.95 for MTP, 0.90 for DSpark.
#     Upstream wedged the box into a hard reboot at 0.95 with a draft model
#     loaded, so the drafted modes get the lower value. NOTE this claims nearly
#     the whole 128 GB unified pool — unlike the vLLM scripts in this folder,
#     which default to 0.45 to leave room for a second model. Lower
#     MEM_FRACTION_STATIC if you are sharing the box.
#
#   - --cpuset-cpus 5-9,15-19 pins the container to GB10's ten 3.9 GHz Cortex-X5
#     cores, keeping the scheduler and tokenizer off the 2.8 GHz A725 efficiency
#     cores (0-4, 10-14). Measured +2-7% decode upstream. CPUSET="" disables.
#
#   - --disable-prefill-cuda-graph per the cookbook's Spark cell. Upstream
#     rejected prefill CUDA graphs on measurement; PREFILL_CUDA_GRAPH=1 re-enables
#     if you want to retest.
#
#   - YaRN to 1M context, MTP only. Above the native 262144 the script injects a
#     rope_parameters override and sets SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN
#     (this build ignores a longer --context-length without it). The override
#     leaks into the draft model's config and crashes the rope validator on the
#     drafted modes, so the script refuses YaRN when SPEC_MODE=dspark.
#
#   - Thinking is ON by default (the chat template sets enable_thinking and
#     preserve_thinking). --reasoning-parser qwen3 surfaces the <think> block as
#     reasoning_content instead of inline text. Disable per request with
#     chat_template_kwargs {"enable_thinking": false}. Tool calling uses
#     qwen3_coder; SGLang needs no vLLM-style --enable-auto-tool-choice, just
#     send `tools` in the request.
#
# ----------------------------------------------------------------------------
# Port note: defaults to 8000, the same port the vLLM scripts in this folder use.
# Only one of them can hold it at a time — stop the vLLM container first, or pass
# PORT=8888 (or anything free) to run both side by side.

set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
QUANT="${QUANT:-nvfp4}"
case "$QUANT" in
  nvfp4)     MODEL="RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead" ;;  # dense BF16 head (default)
  nvfp4-fp4) MODEL="RadixArk/Qwen3.8-27B-NVFP4" ;;              # packed FP4 head, ~2 GB smaller
  fp8)       MODEL="Qwen/Qwen3.8-27B-FP8" ;;
  bf16)      MODEL="Qwen/Qwen3.8-27B" ;;                        # ~52 GB weights
  *) echo "ERROR: unknown QUANT '$QUANT' (use nvfp4|nvfp4-fp4|fp8|bf16)" >&2; exit 1 ;;
esac
MODEL="${MODEL_OVERRIDE:-$MODEL}"
SERVED_NAME="${SERVED_NAME:-$MODEL}"
IMAGE="${IMAGE:-lmsysorg/sglang:qwen38-27b}"
PORT="${PORT:-8000}"
HOST_BIND="${HOST_BIND:-0.0.0.0}"    # SGLang --host; 127.0.0.1 restricts to this box
CONTAINER_NAME="${CONTAINER_NAME:-sglang-qwen38}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
TRITON_CACHE="${TRITON_CACHE:-$HOME/.cache/triton}"
SHM_SIZE="${SHM_SIZE:-32g}"
CPUSET="${CPUSET:-5-9,15-19}"        # GB10 Cortex-X5 cores; "" disables pinning
PRIVILEGED="${PRIVILEGED:-0}"        # upstream runs --privileged; off here unless you need it

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

SPEC_MODE="${SPEC_MODE:-mtp}"                       # mtp | dspark
CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"          # 262144 .. 1000000
YARN="${YARN:-0}"                                   # 1 required above native, MTP only
MAX_CONCURRENT_REQUESTS="${MAX_CONCURRENT_REQUESTS:-10}"
CHUNKED_PREFILL="${CHUNKED_PREFILL:-8192}"
ATTENTION_BACKEND="${ATTENTION_BACKEND:-flashinfer}"  # required on sm_121; triton = fallback
MAMBA_SKIP_DECODE_LOCK="${MAMBA_SKIP_DECODE_LOCK:-0}"
PREFILL_CUDA_GRAPH="${PREFILL_CUDA_GRAPH:-0}"
SKIP_PRESTAGE="${SKIP_PRESTAGE:-0}"

# MTP knobs (chain drafting: topk must be 1, draft must be steps + 1).
SPEC_STEPS="${SPEC_STEPS:-3}"
SPEC_TOPK="${SPEC_TOPK:-1}"
SPEC_DRAFT="${SPEC_DRAFT:-4}"

# DSpark knobs.
DSPARK_DRAFT_MODEL="${DSPARK_DRAFT_MODEL:-RadixArk/Qwen3.8-27B-DSpark}"
DSPARK_BLOCK_SIZE="${DSPARK_BLOCK_SIZE:-7}"         # 7 = code peak; 5 = +8% prose / -16% code
DSPARK_NUM_DRAFT="${DSPARK_NUM_DRAFT:-8}"

# Memory fraction defaults per mode (see Design decisions).
if [[ "$SPEC_MODE" == "dspark" ]]; then
  MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.90}"
else
  MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.95}"
fi

REASONING_PARSER="${REASONING_PARSER:-qwen3}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# ---- Validate ---------------------------------------------------------------
case "$SPEC_MODE" in
  mtp|dspark|none) : ;;
  *) echo "ERROR: SPEC_MODE must be mtp, dspark, or none (got '$SPEC_MODE')" >&2; exit 1 ;;
esac

if (( CONTEXT_LENGTH < 262144 || CONTEXT_LENGTH > 1000000 )); then
  echo "ERROR: CONTEXT_LENGTH must be 262144..1000000 (got $CONTEXT_LENGTH)" >&2
  exit 1
fi

if [[ "$SPEC_MODE" == "mtp" ]]; then
  if [[ "$SPEC_TOPK" != "1" ]]; then
    echo "ERROR: SPEC_TOPK must be 1 (this recipe wires MTP chain drafting)." >&2
    exit 1
  fi
  if (( SPEC_DRAFT != SPEC_STEPS + 1 )); then
    echo "ERROR: chain drafting needs SPEC_DRAFT = SPEC_STEPS + 1 (got steps=$SPEC_STEPS draft=$SPEC_DRAFT)." >&2
    exit 1
  fi
fi

# YaRN: needed above native context, and incompatible with a separate drafter.
NEED_YARN=0
if (( CONTEXT_LENGTH > 262144 )); then
  if [[ "$YARN" == "1" || "$CONTEXT_LENGTH" == "1000000" ]]; then
    NEED_YARN=1
  else
    echo "ERROR: CONTEXT_LENGTH=$CONTEXT_LENGTH needs YaRN. Set YARN=1." >&2
    exit 1
  fi
fi
if (( NEED_YARN )) && [[ "$SPEC_MODE" == "dspark" ]]; then
  echo "ERROR: YaRN is not compatible with SPEC_MODE=dspark on this build." >&2
  echo "       The rope override leaks into the draft model's config and crashes" >&2
  echo "       transformers' rope validator (AttributeError: max_position_embeddings)." >&2
  echo "       Use SPEC_MODE=mtp for long context, or keep CONTEXT_LENGTH=262144." >&2
  exit 1
fi

# ---- Assemble flags ---------------------------------------------------------
# GDN state pool: slots = concurrency x S. Verify states are a separate buffer.
MAMBA_SLOTS_PER_REQ=$(( 4 - MAMBA_SKIP_DECODE_LOCK ))
MAMBA_CACHE_SIZE=$(( MAX_CONCURRENT_REQUESTS * MAMBA_SLOTS_PER_REQ ))

CONTEXT_ARGS=(--context-length "$CONTEXT_LENGTH")
ALLOW_LONGER_ENV=()
YARN_NOTE=""
if (( NEED_YARN )); then
  # factor = round(len / 262144); the card validates 2.0 (512K) and 4.0 (1M).
  YARN_FACTOR="$(awk -v n="$CONTEXT_LENGTH" 'BEGIN{printf "%.0f", n/262144}')"
  (( YARN_FACTOR < 1 )) && YARN_FACTOR=1
  YARN_OVERRIDE="$(printf '{"text_config": {"rope_parameters": {"mrope_interleaved": true, "mrope_section": [11, 11, 10], "rope_type": "yarn", "rope_theta": 10000000, "partial_rotary_factor": 0.25, "factor": %s, "original_max_position_embeddings": 262144}}}' "$YARN_FACTOR")"
  CONTEXT_ARGS=(--json-model-override-args "$YARN_OVERRIDE" --context-length "$CONTEXT_LENGTH")
  # Without this the build ignores the longer --context-length and stays at 262K.
  ALLOW_LONGER_ENV=(-e SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1)
  YARN_NOTE=" (YaRN factor $YARN_FACTOR)"
fi

SPEC_ARGS=()
DRAFT_MODEL=""
case "$SPEC_MODE" in
  mtp)
    SPEC_ARGS=(
      --speculative-algorithm EAGLE
      --speculative-num-steps "$SPEC_STEPS"
      --speculative-eagle-topk "$SPEC_TOPK"
      --speculative-num-draft-tokens "$SPEC_DRAFT"
    )
    ;;
  dspark)
    DRAFT_MODEL="$DSPARK_DRAFT_MODEL"
    SPEC_ARGS=(
      --speculative-algorithm DSPARK
      --speculative-draft-model-path "$DSPARK_DRAFT_MODEL"
      --speculative-dspark-block-size "$DSPARK_BLOCK_SIZE"
      --speculative-draft-model-quantization unquant
      --speculative-num-draft-tokens "$DSPARK_NUM_DRAFT"
      --enable-torch-compile --torch-compile-max-bs 4
      --cuda-graph-max-bs-decode 4
      --num-continuous-decode-steps 2
    )
    ;;
  none) SPEC_ARGS=() ;;
esac

PREFILL_GRAPH_ARGS=(--disable-prefill-cuda-graph)
[[ "$PREFILL_CUDA_GRAPH" == "1" ]] && PREFILL_GRAPH_ARGS=()

PIN_ARGS=()
[[ -n "$CPUSET" ]] && PIN_ARGS=(--cpuset-cpus "$CPUSET")

PRIV_ARGS=()
[[ "$PRIVILEGED" == "1" ]] && PRIV_ARGS=(--privileged)

read -ra EXTRA_ARGS_ARR <<< "$EXTRA_ARGS"

# ---- Pre-flight -------------------------------------------------------------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "WARNING: HF_TOKEN is not set. Downloads fall back to anonymous rate limits." >&2
fi
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is not on PATH" >&2; exit 1; }
command -v curl  >/dev/null 2>&1 || { echo "ERROR: curl is not on PATH" >&2; exit 1; }

mkdir -p "$HF_CACHE" "$TRITON_CACHE"

# ---- Pre-stage weights ------------------------------------------------------
if [[ "$SKIP_PRESTAGE" != "1" ]]; then
  for m in "$MODEL" ${DRAFT_MODEL:+$DRAFT_MODEL}; do
    echo "Pre-staging $m into $HF_CACHE ..."
    docker run --rm \
      -e HF_TOKEN="${HF_TOKEN:-}" \
      -e MODEL="$m" \
      -v "${HF_CACHE}:/root/.cache/huggingface" \
      --entrypoint bash \
      "$IMAGE" \
      -c 'if command -v hf >/dev/null 2>&1; then hf download "$MODEL"; else huggingface-cli download "$MODEL"; fi'
  done
  echo "Pre-stage complete."
else
  echo "Skipping pre-stage (SKIP_PRESTAGE=1); weights will load from existing cache."
fi

# ---- Launch -----------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Removing existing container '$CONTAINER_NAME'..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "Starting SGLang container '$CONTAINER_NAME'"
echo "  Model:       $MODEL  (QUANT=$QUANT)"
echo "  Context:     ${CONTEXT_LENGTH}${YARN_NOTE}"
echo "  Concurrency: $MAX_CONCURRENT_REQUESTS  (GDN pool $MAMBA_CACHE_SIZE slots @ ${MAMBA_SLOTS_PER_REQ}/req)"
echo "  Spec decode: $SPEC_MODE"
echo "  Mem frac:    $MEM_FRACTION_STATIC"
echo "  Attention:   $ATTENTION_BACKEND"
[[ -n "$CPUSET" ]] && echo "  CPU pinning: $CPUSET"

docker run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  --ipc host \
  --gpus all \
  --shm-size "$SHM_SIZE" \
  --restart unless-stopped \
  "${PIN_ARGS[@]}" \
  "${PRIV_ARGS[@]}" \
  -e HF_HOME=/root/.cache/huggingface \
  -e TRITON_CACHE_DIR=/root/.triton \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -e SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK="$MAMBA_SKIP_DECODE_LOCK" \
  "${ALLOW_LONGER_ENV[@]}" \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  -v "${TRITON_CACHE}:/root/.triton" \
  "$IMAGE" \
  python3 -m sglang.launch_server \
  --model-path "$MODEL" \
  --served-model-name "$SERVED_NAME" \
  --trust-remote-code \
  --mem-fraction-static "$MEM_FRACTION_STATIC" \
  --attention-backend "$ATTENTION_BACKEND" \
  --chunked-prefill-size "$CHUNKED_PREFILL" \
  "${PREFILL_GRAPH_ARGS[@]}" \
  --kv-cache-dtype fp8_e4m3 \
  --mamba-ssm-dtype bfloat16 \
  --mamba-full-memory-ratio 4.21 \
  --mamba-radix-cache-strategy extra_buffer_lazy \
  --max-mamba-cache-size "$MAMBA_CACHE_SIZE" \
  --max-running-requests "$MAX_CONCURRENT_REQUESTS" \
  "${CONTEXT_ARGS[@]}" \
  ${SPEC_ARGS[@]+"${SPEC_ARGS[@]}"} \
  --reasoning-parser "$REASONING_PARSER" \
  --tool-call-parser "$TOOL_PARSER" \
  --sampling-defaults model \
  --enable-metrics \
  --enable-cache-report \
  --api-key "$API_KEY" \
  --host "$HOST_BIND" \
  --port "$PORT" \
  ${EXTRA_ARGS_ARR[@]+"${EXTRA_ARGS_ARR[@]}"} \
  >/dev/null

# ---- Wait for readiness -----------------------------------------------------
AUTH_HEADER="Authorization: Bearer ${API_KEY}"
echo "Waiting for readiness (weight load + graph capture takes several minutes)..."
echo "Streaming container logs below (Ctrl-C stops the script, not the container):"
echo "------------------------------------------------------------------------------"

# The per-layer "Enabled fused SiLU+mul+FP4-quant..." notice fires once per MLP
# layer and drowns the real startup log; filter it from the terminal copy only.
docker logs -f "$CONTAINER_NAME" 2>&1 \
  | grep --line-buffered -v "Enabled fused SiLU+mul+FP4-quant for dense MLP down_proj input" &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

until curl -sf -H "$AUTH_HEADER" "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    kill "$LOG_PID" 2>/dev/null || true
    echo "------------------------------------------------------------------------------"
    echo "ERROR: container '$CONTAINER_NAME' exited during startup. Last 50 log lines:" >&2
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 50 >&2
    echo >&2
    echo "If this was a speculative-decode error at boot, retry with ATTENTION_BACKEND=triton." >&2
    exit 1
  fi
  sleep 5
done

kill "$LOG_PID" 2>/dev/null || true
trap - EXIT
echo "------------------------------------------------------------------------------"
echo "Server is up."

# Confirm the scheduler cap actually stuck — speculative decoding silently
# resets max_running_requests to 48 when it is not pinned.
ACTUAL_CAP="$(docker logs "$CONTAINER_NAME" 2>&1 | grep -o 'max_running_requests=[0-9]*' | tail -1 || true)"
[[ -n "$ACTUAL_CAP" ]] && echo "Scheduler cap: $ACTUAL_CAP (expected max_running_requests=$MAX_CONCURRENT_REQUESTS)"

# ---- Warm up ----------------------------------------------------------------
echo "Warming up with a 3-token request..."
curl -sf "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d "{\"model\":\"${SERVED_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" \
  >/dev/null && echo "Warm-up done." || echo "Warm-up request failed (server may still be loading)."

echo
echo "Ready.    http://localhost:${PORT}/v1"
echo "Metrics:  http://localhost:${PORT}/metrics"
echo "Logs:     docker logs -f ${CONTAINER_NAME}"
echo
echo "Thinking is ON by default; disable per request with"
echo "  chat_template_kwargs: {\"enable_thinking\": false}"
if [[ "$API_KEY_GENERATED" == "1" ]]; then
  echo "API key (auto-generated this run): ${API_KEY}"
  echo "  Pin it with API_KEY=... next run to keep it stable across restarts."
else
  echo "API key: (provided via API_KEY)"
fi
echo "  Clients must send:  Authorization: Bearer ${API_KEY}"
