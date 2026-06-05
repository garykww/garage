#!/usr/bin/env bash
#
# benchmark-gemma4.sh
# A small, purposeful GuideLLM suite for the Gemma-4-26B-A4B-NVFP4 vLLM server
# (the one launched by run-gemma4-spark.sh: 128K context, max-num-seqs=4,
# prefix caching ON, full-precision KV).
#
# Three runs bracket the system from best-case latency to saturation; a fourth
# stress-tests behavior under large prompts:
#
#   1. FLOOR     (synchronous)         one request at a time. Pure per-request
#                                      latency with zero contention — the best
#                                      TTFT / ITL / e2e your agents can ever see.
#   2. OPERATING (concurrent 1,2,4)    realistic agentic load WITH a shared
#                                      system-prompt+tools prefix and prefix
#                                      caching active. Shows how latency scales
#                                      from 1 up to your max-num-seqs=4 ceiling.
#   3. CEILING   (throughput, cold)    fire everything in parallel, NO shared
#                                      prefix (cache-cold), to find max sustained
#                                      token throughput and where queueing blows up.
#   4. LARGE CTX (concurrent 1,2,4)    ~32K prompts, cache-cold. Stresses prefill
#                                      TTFT and KV capacity at high context — the
#                                      real test of the 128K + 4-concurrency config.
#
# Shape (your real usage): ~8K prompt in, ~1K generated out, with realistic
# variance (stdev + min/max) rather than a single fixed length.
#
# Why this is more meaningful than a fixed 256/128 sweep:
#   - Matches what the server was tuned for (long context, low concurrency).
#   - Separates cache-warm (agentic) from cache-cold (capacity) measurement,
#     instead of letting sweep's request-replay muddy prefix-cache effects.
#   - Pins the real Gemma-4 tokenizer so "8192 tokens" is actually 8192 tokens.
#   - Warms up / cools down so JIT cold-start and shutdown don't skew stats.
#
# Usage:
#   export API_KEY=sk-...        # the key printed by run-gemma4-spark.sh
#   ./benchmark-gemma4.sh                 # run all four (floor, operating, ceiling, large)
#   ./benchmark-gemma4.sh 2                # run only the operating/SLO benchmark
#   ./benchmark-gemma4.sh floor large      # run a chosen subset, in order
#   ./benchmark-gemma4.sh --help           # list the runs and selectors
#
set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
TARGET="${TARGET:-http://localhost:8000}"
MODEL="${MODEL:-nvidia/Gemma-4-26B-A4B-NVFP4}"
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
# Large-context shape: ~32K in / 512 out. Bounded so 4 concurrent sessions still
# fit the KV pool without preemption (4 x ~49K worst case stays under capacity).
LARGE_SHAPE="prompt_tokens=32768,prompt_tokens_stdev=4096,prompt_tokens_min=16384,prompt_tokens_max=49152,output_tokens=512,output_tokens_stdev=128,output_tokens_min=256,output_tokens_max=1024"

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
  # Scales from a single agent up to max-num-seqs=4. The rate=4 point is your
  # real expected-load SLO number.
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
  # Sweep request rates to find max sustained throughput and where queueing
  # latency blows up. GuideLLM's throughput profile requires an explicit --rate;
  # sweeping 1,2,4,8 brackets the Spark's max-num-seqs=4 ceiling and shows the
  # saturation knee.
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

run_large() {  # 4 — ~32K prompts, concurrent 1/2/4, cache-cold
  # Each request prefills its full ~32K (no shared prefix), so this measures
  # true large-prompt TTFT and whether 4 concurrent big-context sessions fit
  # the KV pool without preemption. The real stress test of 128K + 4-seq.
  echo "==> LARGE CTX: ~32K-in / 512-out, concurrent 1,2,4 (cache-cold)"
  guidellm benchmark \
    --target "$TARGET" \
    --model "$MODEL" \
    --processor "$PROCESSOR" \
    --backend-kwargs "$BACKEND_KWARGS" \
    --profile concurrent \
    --rate 1,2,4 \
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
Usage: ./benchmark-gemma4.sh [runs...]

Select which benchmark(s) to run by number or name (space-separated).
Runs in the order given; with no arguments, runs all four in order.

  1 | floor       best-case latency, one request at a time (synchronous)
  2 | operating   latency vs concurrency 1->4, cache-warm (agentic prefix)
  3 | ceiling     max throughput + saturation, cache-cold (throughput)
  4 | large       ~32K-prompt prefill cost + KV fit at 1->4, cache-cold

Examples:
  ./benchmark-gemma4.sh              # all four
  ./benchmark-gemma4.sh 2            # just the operating/SLO run
  ./benchmark-gemma4.sh floor large  # floor, then large-context
  ./benchmark-gemma4.sh 1 2 3 4      # explicit all

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
  echo "ERROR: API_KEY is not set. Export the key printed by run-gemma4-spark.sh:" >&2
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
echo "  4_large_context.json        - ~32K-prompt prefill cost + KV fit at 1->4"
echo "(only the files for the runs you selected are present)"
