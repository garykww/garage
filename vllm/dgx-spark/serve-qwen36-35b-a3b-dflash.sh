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

    --served-model-name RedHatAI/Qwen3.6-35B-A3B-NVFP4
    --gpu-memory-utilization 0.70
    --max-model-len 131072
    --max-num-seqs 4
    --max-num-batched-tokens 16384
    --kv-cache-dtype auto
    --trust-remote-code
    --enable-prefix-caching
    --enable-chunked-prefill
    --enable-auto-tool-choice
    --tool-call-parser qwen3
    --reasoning-parser qwen3_coder
    --chat-template '{"thinking": true}'

    # DFlash: 15 draft tokens per step
    --speculative-config "{\"method\":\"dflash\",\"num_speculative_tokens\":15,\"model\":\"${DRAFT_MODEL}\"}"
)

exec bash "$(dirname "$0")/serve.sh" "${args[@]}" "$@"
