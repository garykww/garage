#!/usr/bin/env bash
#
# benchmark-qwen38-27b-mtp.sh
# A small, purposeful GuideLLM suite for the Qwen3.8-27B-NVFP4 vLLM server
# (the one launched by serve-qwen38-27b-mtp.sh: 262K native context,
# max-num-seqs=4, MTP speculative decoding, prefix caching ON).
#
# Same four-run bracket as benchmark-gemma4.sh, sized for this model's much
# larger native context window:
#
#   1. FLOOR     (synchronous)         one request at a time. Pure per-request
#                                      latency with zero contention.
#   2. OPERATING (concurrent 1,2,4)    realistic agentic load WITH a shared
#                                      system-prompt+tools prefix and prefix
#                                      caching active, up to max-num-seqs=4.
#   3. CEILING   (throughput, cold)    fire everything in parallel, NO shared
#                                      prefix (cache-cold), to find max sustained
#                                      token throughput and where queueing blows up.
#   4. LARGE CTX (concurrent 1,2)      ~64K prompts, cache-cold. Only 1,2 (not 4)
#                                      to stay well under the KV pool at
#                                      gpu-memory-utilization=0.5 (measured
#                                      ~910K-token KV pool / 3.47x concurrency
#                                      at full 262K context).
#
# Requires: pip install "guidellm<0.7" (tested on 0.6.1). guidellm>=0.7
# restructured its CLI (the `benchmark` subcommand and these flags are gone,
# replaced by a `kind=...` config syntax) — `pip install guidellm` alone will
# grab the newer CLI and every command below will fail with "No such command
# 'benchmark'".
#
# Usage:
#   export API_KEY=sk-...        # the key printed by serve-qwen38-27b-mtp.sh
#   ./benchmark-qwen38-27b-mtp.sh                 # run all four (floor, operating, ceiling, large)
#   ./benchmark-qwen38-27b-mtp.sh 2                # just the operating/SLO run
#   ./benchmark-qwen38-27b-mtp.sh floor operating  # a chosen subset, in order
#   ./benchmark-qwen38-27b-mtp.sh --help           # list the runs and selectors
#
set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
TARGET="${TARGET:-http://localhost:8001}"
MODEL="${MODEL:-unsloth/Qwen3.8-27B-NVFP4}"
# Tokenizer used to compute token counts + generate synthetic data. Same as the
# model; its files are already in your HF cache from serving.
PROCESSOR="${PROCESSOR:-$MODEL}"
API_KEY="${API_KEY:-}"
OUT_DIR="${OUT_DIR:-./guidellm-results}"

# ---- Shared data shape ------------------------------------------------------
# ~8K in / ~1K out with variance. min/max keep the generator in a sane band.
SHAPE="prompt_tokens=8192,prompt_tokens_stdev=1024,prompt_tokens_min=4096,prompt_tokens_max=16384,output_tokens=1024,output_tokens_stdev=256,output_tokens_min=512,output_tokens_max=2048"
# Agentic prefix: ~2K shared tokens standing in for a system prompt + tool
# schemas. With server-side prefix caching ON, repeated requests hit the cached
# prefix — which is the realistic agentic behavior we WANT to measure here.
PREFIX="prefix_tokens=2048"
# Large-context shape: ~64K in / 512 out — a meaningful fraction of the 262K
# native window without risking KV preemption at concurrency 2.
LARGE_SHAPE="prompt_tokens=65536,prompt_tokens_stdev=8192,prompt_tokens_min=32768,prompt_tokens_max=98304,output_tokens=512,output_tokens_stdev=128,output_tokens_min=256,output_tokens_max=1024"

# =============================================================================
# Each benchmark is a function so it can be selected individually.
# =============================================================================

run_floor() {  # 1 — best-case latency, one request at a time
  echo "==> FLOOR: synchronous single-stream latency"
  guidellm benchmark \
    --target "$TARGET" \
    --model "$MODEL" \
    --processor "$PROCESSOR" \
    --backend-kwargs "$BACKEND_KWARGS" \
    --profile synchronous \
    --warmup 0.1 \
    --cooldown 0.1 \
    --max-seconds 240 \
    --max-errors 5 \
    --data "kind=synthetic_text,$SHAPE" \
    --output-path "$OUT_DIR/1_floor_synchronous.json"
}

run_operating() {  # 2 — concurrent 1/2/4 with shared prefix + prefix caching
  echo "==> OPERATING: concurrent 1,2,4 with agentic shared prefix"
  guidellm benchmark \
    --target "$TARGET" \
    --model "$MODEL" \
    --processor "$PROCESSOR" \
    --backend-kwargs "$BACKEND_KWARGS" \
    --profile concurrent \
    --rate 1,2,4 \
    --warmup 0.1 \
    --cooldown 0.1 \
    --max-seconds 180 \
    --max-errors 5 \
    --data "kind=synthetic_text,$PREFIX,$SHAPE" \
    --output-path "$OUT_DIR/2_operating_concurrent.json"
}

run_ceiling() {  # 3 — throughput sweep, cache-cold (no shared prefix)
  echo "==> CEILING: throughput sweep 1,2,4,8 req/s (cache-cold, no prefix)"
  guidellm benchmark \
    --target "$TARGET" \
    --model "$MODEL" \
    --processor "$PROCESSOR" \
    --backend-kwargs "$BACKEND_KWARGS" \
    --profile throughput \
    --rate 1,2,4,8 \
    --warmup 0.1 \
    --cooldown 0.1 \
    --max-seconds 180 \
    --max-errors 5 \
    --data "kind=synthetic_text,$SHAPE" \
    --output-path "$OUT_DIR/3_ceiling_throughput.json"
}

run_large() {  # 4 — ~64K prompts, concurrent 1/2, cache-cold
  echo "==> LARGE CTX: ~64K-in / 512-out, concurrent 1,2 (cache-cold)"
  guidellm benchmark \
    --target "$TARGET" \
    --model "$MODEL" \
    --processor "$PROCESSOR" \
    --backend-kwargs "$BACKEND_KWARGS" \
    --profile concurrent \
    --rate 1,2 \
    --warmup 0.1 \
    --cooldown 0.1 \
    --max-seconds 240 \
    --max-errors 5 \
    --data "kind=synthetic_text,$LARGE_SHAPE" \
    --output-path "$OUT_DIR/4_large_context.json"
}

# ---- Selection --------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: ./benchmark-qwen38-27b-mtp.sh [runs...]

Select which benchmark(s) to run by number or name (space-separated).
Runs in the order given; with no arguments, runs all four in order.

  1 | floor       best-case latency, one request at a time (synchronous)
  2 | operating   latency vs concurrency 1->4, cache-warm (agentic prefix)
  3 | ceiling     max throughput + saturation, cache-cold (throughput)
  4 | large       ~64K-prompt prefill cost + KV fit at 1->2, cache-cold

Examples:
  ./benchmark-qwen38-27b-mtp.sh              # all four
  ./benchmark-qwen38-27b-mtp.sh 2            # just the operating/SLO run
  ./benchmark-qwen38-27b-mtp.sh floor large  # floor, then large-context
  ./benchmark-qwen38-27b-mtp.sh 1 2 3 4      # explicit all

Env overrides: API_KEY (required), TARGET, MODEL, PROCESSOR, OUT_DIR
EOF
}

# Map a selector token to a function name.
resolve_run() {
  case "$1" in
    1|floor)            echo run_floor ;;
    2|operating|slo)    echo run_operating ;;
    3|ceiling|throughput) echo run_ceiling ;;
    4|large|large-ctx|largectx) echo run_large ;;
    *) return 1 ;;
  esac
}

# Parse arguments into an ordered list of functions to execute.
SELECTED=()
if [[ $# -eq 0 ]]; then
  SELECTED=(run_floor run_operating run_ceiling run_large)
else
  for arg in "$@"; do
    case "$arg" in
      -h|--help|help) usage; exit 0 ;;
    esac
    if fn="$(resolve_run "$arg")"; then
      SELECTED+=("$fn")
    else
      echo "ERROR: unknown run '$arg'" >&2
      echo >&2
      usage >&2
      exit 2
    fi
  done
fi

# API key is only needed once we're actually going to run something.
if [[ -z "$API_KEY" ]]; then
  echo "ERROR: API_KEY is not set. Export the key printed by serve-qwen38-27b-mtp.sh:" >&2
  echo "       export API_KEY=sk-...   (then re-run)" >&2
  exit 1
fi
mkdir -p "$OUT_DIR"
BACKEND_KWARGS="{\"api_key\": \"$API_KEY\"}"

# ---- Execute selected runs --------------------------------------------------
total=${#SELECTED[@]}
i=0
for fn in "${SELECTED[@]}"; do
  i=$((i + 1))
  echo "==> [$i/$total]"
  "$fn"
done

echo
echo "Done. Results in: $OUT_DIR/"
echo "  1_floor_synchronous.json    - best-case latency (no contention)"
echo "  2_operating_concurrent.json - latency vs concurrency 1->4 (cache-warm)"
echo "  3_ceiling_throughput.json   - max throughput + saturation (cache-cold)"
echo "  4_large_context.json        - ~64K-prompt prefill cost + KV fit at 1->2"
echo "(only the files for the runs you selected are present)"
