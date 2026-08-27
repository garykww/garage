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
#   SPEC_MODE=dspark                   method=dspark, needs vLLM >= 0.25   yes*
#   SPEC_MODE=dflash2                  method=dflash, needs vLLM >= 0.27.1 yes*
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
# DSpark ports only on a newer image. `dspark` is absent from the spark-arena
# 0.22 build's method list but PRESENT in vLLM 0.28.0 (verified by reading
# SpeculativeMethod's literals in both images). So SPEC_MODE=dspark switches to
# the same newer image dflash2 uses, and is refused only if you force IMAGE back
# to a build that lacks it. Upstream reports DSpark's adaptive-verification
# confidence head is inert on Qwen3.8 under vLLM, because GDN layers use
# GDNAttentionBackend — so you get block drafting without adaptive verify.
#
# DFlash2 DOES port, on a newer image. SPEC_MODE=dflash2 uses the in-tree
# `dflash` method with the incoai/Qwen3.8-27B-DFlash2 drafter. Two hard
# requirements, both enforced below rather than left to fail at load:
#
#   1. vLLM >= 0.27.1. `dflash` is present in 0.22 but that is DFlash*1*; a
#      DFlash2 checkpoint on an old runtime DRAFTS AS DFLASH1 SILENTLY rather
#      than erroring. Selecting dflash2 therefore switches the default IMAGE to
#      vllm/vllm-openai:v0.28.0-aarch64 (arm64, CUDA 13.0.2) instead of the
#      spark-arena 0.22 build.
#   2. An UNQUANTIZED LM HEAD. The DFlash2 selector reads the target's top-16
#      candidates straight off the head, so vLLM refuses a quantized one.
#      QUANT=fp8 and QUANT=bf16 qualify. QUANT=nvfp4-fp4 and QUANT=unsloth do
#      not — their checkpoints carry lm_head.weight_scale / weight_scale_2 /
#      input_scale sidecars — and are refused.
#
#      QUANT=nvfp4 (RadixArk NVFP4-BF16-LMHead) WORKS, contradicting upstream.
#      Upstream states flatly that 4-bit checkpoints are blocked "including
#      NVFP4", but that export exists precisely to keep a dense BF16 head, and
#      its safetensors index carries no lm_head quantization sidecars at all —
#      unlike RadixArk/Qwen3.8-27B-NVFP4, which has all three. MEASURED on a
#      DGX Spark 2026-08-28, vLLM 0.28.0, this exact script, MAX_NUM_SEQS=1:
#
#        server started clean; quantization resolved to modelopt_mixed
#        "Resolved architecture: DFlash2DraftModel"  <- V2, not a DFlash1 fallback
#        mean acceptance length 4.70 (upstream reports 4.607 on FP8)
#        per-position acceptance 0.825 0.737 0.544 0.474 0.386 0.368 0.368
#        avg draft acceptance 52.9%
#        45.6 tok/s on code, 28.9 tok/s on prose, 256 max_tokens, temperature 0
#
#      So 4-bit NVFP4 + DFlash2 is real on this export, at acceptance parity
#      with upstream's FP8 numbers — and it saves the ~27 GB FP8 download.
#
#   Cost and shape, measured by upstream on a Spark (FP8 target): +3.77 GiB for
#   the drafter, KV pool down ~37% (980K -> 617K tokens), +30 s load. 29.86
#   tok/s fresh single-stream, 49.20 edit-heavy, acceptance length 4.607.
#   BUT the crossover is at c=2: at concurrency >= 2 DFlash2 LOSES to 4-bit+MTP.
#   This script defaults MAX_NUM_SEQS=10, so dflash2 warns if you leave it there.
#   k caps at 7 (the drafter's dflash_config.block_size is 8).
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
#   - Throughput for the MTP and DSpark modes. The SGLang README's numbers were
#     measured under SGLang and do not transfer. The dflash2 + nvfp4 figures
#     above ARE from this script on this box; nothing else here is.
#
# VERIFIED on Spark 2026-08-28 (vLLM 0.28.0 image): CUDA graph capture works on
# sm_121 despite sm_121 being absent from torch's compiled arch list — FlashInfer
# JITs for 121a at runtime. "Capturing dflash2 CUDA graphs (FULL)" completed.
#
# ----------------------------------------------------------------------------
# Entrypoint note: the two images disagree. ghcr.io/spark-arena/... does NOT set
# `vllm serve` as its ENTRYPOINT (the other scripts in this folder prepend it),
# while the official vllm/vllm-openai image DOES — passing `vllm serve ...` to
# the latter yields `vllm serve vllm serve <model>` and argparse rejects it. So
# this script pins --entrypoint vllm and passes `serve` itself, which is correct
# for both regardless of which IMAGE you point it at.
#
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

SPEC_MODE="${SPEC_MODE:-mtp}"                        # mtp | dflash2 | dspark | none
SPEC_TOKENS="${SPEC_TOKENS:-3}"                      # SGLang SPEC_STEPS=3 peak maps to this

# DFlash2 needs vLLM >= 0.27.1, which the spark-arena build (0.22) does not
# meet, so the default image depends on the mode. Both are arm64 + CUDA 13.
# vllm/vllm-openai:v0.28.0-aarch64 for every mode: arm64, CUDA 13.0.2, and
# verified running end-to-end on GB10 (a real generate, not just an import).
# The drafted modes REQUIRE it (dflash2 needs >= 0.27.1, dspark >= 0.25); MTP
# would also run on the older spark-arena 0.22 build, but defaulting to two
# different images by mode makes the effective runtime depend on a flag you did
# not set, which is worse than the version bump. Set IMAGE=ghcr.io/spark-arena/
# dgx-vllm-eugr-nightly to pin the 0.22 build back for MTP.
IMAGE="${IMAGE:-vllm/vllm-openai:v0.28.0-aarch64}"
DFLASH2_DRAFT_MODEL="${DFLASH2_DRAFT_MODEL:-incoai/Qwen3.8-27B-DFlash2}"
DFLASH2_TOKENS="${DFLASH2_TOKENS:-7}"                # caps at 7 (block_size 8)
DSPARK_DRAFT_MODEL="${DSPARK_DRAFT_MODEL:-Doopeworld/Qwen3.8-27B-DSpark-vLLM}"
DSPARK_TOKENS="${DSPARK_TOKENS:-7}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"             # 262144 .. 1000000
YARN="${YARN:-0}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-10}"                   # SGLang MAX_CONCURRENT_REQUESTS
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"   # SGLang CHUNKED_PREFILL
ATTENTION_BACKEND="${ATTENTION_BACKEND:-FLASHINFER}" # TRITON_ATTN is the fallback
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"
MAMBA_SSM_CACHE_DTYPE="${MAMBA_SSM_CACHE_DTYPE:-bfloat16}"
MAMBA_CACHE_MODE="${MAMBA_CACHE_MODE:-align}"        # required for GDN on vLLM
# 0.92, not the SGLang recipe's 0.95. vLLM's check is against *free* memory at
# startup, not total: on an otherwise-idle Spark with only a 69 MiB container up,
# free was 114.97 GiB and 0.95 asks for 115.6 — it refuses to start, short by
# 0.63 GiB. 0.92 (~112 GiB) leaves room for the host and whatever else is up.
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.92}"                 # SGLang MEM_FRACTION_STATIC, minus real-world headroom
REASONING_PARSER="${REASONING_PARSER:-qwen3}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
AGENTIC="${AGENTIC:-1}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# ---- Validate ---------------------------------------------------------------
case "$SPEC_MODE" in
  mtp|none) : ;;
  dflash2)
    # Hard requirement: the drafter reads top-16 candidates off an unquantized head.
    case "$QUANT" in
      fp8|bf16) : ;;
      nvfp4)
        echo "NOTE: DFlash2 on QUANT=nvfp4 (RadixArk NVFP4-BF16-LMHead) is measured" >&2
        echo "      working on Spark despite upstream saying 4-bit is blocked: that" >&2
        echo "      export keeps a dense BF16 head. Acceptance length 4.70, 45.6 tok/s" >&2
        echo "      on code at MAX_NUM_SEQS=1. Fall back to QUANT=fp8 if it regresses." >&2 ;;
      *)
        echo "ERROR: SPEC_MODE=dflash2 needs a target with an UNQUANTIZED lm_head." >&2
        echo "       QUANT=$QUANT ships lm_head.weight_scale/input_scale sidecars, which" >&2
        echo "       vLLM's DFlash2 selector refuses. Use QUANT=fp8 (measured by upstream)" >&2
        echo "       or QUANT=bf16; QUANT=nvfp4 is an unproven maybe." >&2
        exit 1 ;;
    esac
    if (( DFLASH2_TOKENS > 7 )); then
      echo "ERROR: DFLASH2_TOKENS caps at 7 (drafter block_size is 8); got $DFLASH2_TOKENS." >&2
      exit 1
    fi
    if (( MAX_NUM_SEQS >= 2 )); then
      echo "NOTE: DFlash2's crossover is at c=2 — at MAX_NUM_SEQS=$MAX_NUM_SEQS it is" >&2
      echo "      expected to LOSE to 4-bit + MTP. It wins single-stream. Set" >&2
      echo "      MAX_NUM_SEQS=1 for the drafted latency win, or use SPEC_MODE=mtp." >&2
    fi
    echo "NOTE: verify DFlash2 actually engaged — a DFlash2 checkpoint on a runtime" >&2
    echo "      older than 0.27.1 drafts as DFlash1 SILENTLY. Check the startup log." >&2
    ;;
  dspark)
    echo "NOTE: DSpark needs vLLM >= 0.25; the default image for this mode is the" >&2
    echo "      0.28.0 build, not the spark-arena 0.22 one. If you overrode IMAGE," >&2
    echo "      make sure it is new enough or vLLM will reject method=dspark." >&2
    echo "NOTE: DSpark's adaptive-verification head is inert on Qwen3.8 under vLLM" >&2
    echo "      (GDN layers use GDNAttentionBackend) — block drafting only." >&2
    ;;
  *) echo "ERROR: SPEC_MODE must be mtp, dflash2, dspark, or none (got '$SPEC_MODE')" >&2; exit 1 ;;
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
elif [[ "$SPEC_MODE" == "dflash2" ]]; then
  SERVE_FLAGS+=(--speculative-config "{\"method\":\"dflash\",\"model\":\"${DFLASH2_DRAFT_MODEL}\",\"num_speculative_tokens\":${DFLASH2_TOKENS}}")
elif [[ "$SPEC_MODE" == "dspark" ]]; then
  SERVE_FLAGS+=(--speculative-config "{\"method\":\"dspark\",\"model\":\"${DSPARK_DRAFT_MODEL}\",\"num_speculative_tokens\":${DSPARK_TOKENS},\"draft_sample_method\":\"probabilistic\"}")
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
  PRESTAGE_MODELS="$MODEL"
  [[ "$SPEC_MODE" == "dflash2" ]] && PRESTAGE_MODELS="$MODEL $DFLASH2_DRAFT_MODEL"
  [[ "$SPEC_MODE" == "dspark" ]] && PRESTAGE_MODELS="$MODEL $DSPARK_DRAFT_MODEL"
  echo "Pre-staging $PRESTAGE_MODELS into $HF_CACHE ..."
  docker run --rm \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -e MODELS="$PRESTAGE_MODELS" \
    -v "${HF_CACHE}:/root/.cache/huggingface" \
    --entrypoint bash \
    "$IMAGE" \
    -c 'for m in $MODELS; do if command -v hf >/dev/null 2>&1; then hf download "$m"; else huggingface-cli download "$m"; fi; done'
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
echo "  image=$IMAGE"
[[ "$SPEC_MODE" == "dflash2" ]] && echo "  drafter=$DFLASH2_DRAFT_MODEL k=$DFLASH2_TOKENS (+3.77 GiB, KV pool -37%)"
[[ "$SPEC_MODE" == "dspark" ]] && echo "  drafter=$DSPARK_DRAFT_MODEL k=$DSPARK_TOKENS"
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
  --entrypoint vllm \
  "$IMAGE" \
  serve "${SERVE_FLAGS[@]}"

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
