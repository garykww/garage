#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/spark-arena/dgx-vllm-eugr-nightly}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"

# Pre-stage the draft model; serve.sh handles the main model.
MAIN_MODEL="RedHatAI/Qwen3.6-35B-A3B-NVFP4"
DRAFT_MODEL="z-lab/Qwen3.6-35B-A3B-DFlash"

if [[ "${SKIP_PRESTAGE:-0}" != "1" ]]; then
    echo "==> Pre-staging draft model: $DRAFT_MODEL"
    mkdir -p "$HF_CACHE"
    docker run --rm \
        -e HF_TOKEN="${HF_TOKEN:-}" \
        -e MODEL="$DRAFT_MODEL" \
        -v "${HF_CACHE}:/root/.cache/huggingface" \
        --entrypoint bash \
        "$IMAGE" \
        -c 'if command -v hf >/dev/null 2>&1; then hf download "$MODEL"; else huggingface-cli download "$MODEL"; fi'
    echo "==> Draft pre-stage complete."
fi

# Default container name for this model; override with CONTAINER_NAME=...
export CONTAINER_NAME="${CONTAINER_NAME:-vllm-qwen36}"
# z-lab recommends --shm-size=16g over --ipc=host for this image
export SHM_SIZE="${SHM_SIZE:-16g}"

args=(
    "$MAIN_MODEL"

    # Canonical HF ID so API clients use it in the model field without remapping
    --served-model-name RedHatAI/Qwen3.6-35B-A3B-NVFP4

    # Lower than the no-speculative baseline (0.85) to leave room for the DFlash
    # draft model's activations and KV cache alongside the target model
    --gpu-memory-utilization 0.60

    # 128K context for long agent histories and tool schemas
    --max-model-len 131072

    # Spark bandwidth ceiling; >4 concurrent decode streams spikes TTFT
    --max-num-seqs 4

    # Conservative prefill chunk size; keeps steps short so the drafter isn't
    # starved during long prefills
    --max-num-batched-tokens 4096

    # Checkpoint ships no KV scaling factors so fp8 falls back to scale=1.0;
    # auto lets vLLM pick full precision to preserve accuracy on long agent loops
    --kv-cache-dtype auto

    # Required for Qwen3.6's custom modelling code
    --trust-remote-code

    # System prompt and tool schemas repeat every turn; cache hits cut TTFT sharply
    --enable-prefix-caching

    # Splits long prompts into chunks so a large prefill doesn't block other decodes
    --enable-chunked-prefill

    # Structured tool-call output required for agent clients
    --enable-auto-tool-choice

    # Qwen3 Coder tool-call serialization format; must match the model's output
    --tool-call-parser qwen_coder

    # Strips and surfaces the <think> reasoning block separately from the response
    --reasoning-parser qwen3

    # Enables thinking/reasoning mode in the chat template at the tokenizer level
    --chat-template '{"thinking": true}'

    # GPUDirect Storage accelerated weight loading — faster cold start from NVMe
    --load-format fastsafetensors

    # DFlash speculative decoding; 8 draft tokens per step for better acceptance
    # rate under higher concurrency
    --speculative-config "{\"method\":\"dflash\",\"num_speculative_tokens\":8,\"model\":\"${DRAFT_MODEL}\"}"
)

exec bash "$(dirname "$0")/serve.sh" "${args[@]}" "$@"
