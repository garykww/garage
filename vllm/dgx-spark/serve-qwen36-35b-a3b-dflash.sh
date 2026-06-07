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
# z-lab recommends --shm-size=16g over --ipc=host for this image. On the Spark's
# unified memory this tmpfs is a lazy cap, not a reservation (single GB10 = no
# cross-GPU NCCL transfer, so actual /dev/shm use is small); --ipc=host is an
# equivalent alternative with no memory advantage either way.
export SHM_SIZE="${SHM_SIZE:-16g}"

args=(
    "$MAIN_MODEL"

    # Canonical HF ID so API clients use it in the model field without remapping
    --served-model-name RedHatAI/Qwen3.6-35B-A3B-NVFP4

    # vLLM loads the target weights (~20 GB NVFP4), the 0.5B DFlash drafter
    # (~1 GB), and the KV cache all *inside* this fraction — the drafter and its
    # KV contend with the target KV cache here, they are not allocated outside
    # it. So this cap is about leaving host headroom on the 128 GB unified pool
    # (GMU fraction + /dev/shm + OS all share it), not about "making room" for
    # the drafter. 0.80 (~102 GB) sits just below the 0.85 no-speculative
    # baseline to absorb the larger prefill activation set from the 32K batched
    # tokens below, while leaving ~26 GB for the host.
    --gpu-memory-utilization 0.80

    # 128K context for long agent histories and tool schemas
    --max-model-len 131072

    # Spark bandwidth ceiling; >4 concurrent decode streams spikes TTFT
    --max-num-seqs 4

    # z-lab's recommended prefill chunk for this pair: larger chunks raise
    # prefill throughput and give the drafter more context per step, at the cost
    # of an ~8x larger activation working set (the main reason GMU is 0.80, not
    # higher) and potentially higher TTFT under concurrency on bandwidth-bound
    # Spark
    --max-num-batched-tokens 32768

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
    --tool-call-parser qwen3_coder

    # Strips and surfaces the <think> reasoning block separately from the response
    --reasoning-parser qwen3

    # Enables thinking/reasoning mode in the chat template at the tokenizer level
    --chat-template '{"thinking": true}'

    # GPUDirect Storage accelerated weight loading — faster cold start from NVMe
    --load-format fastsafetensors

    # DFlash speculative decoding; 15 draft tokens per step is z-lab's
    # recommended block depth for this pair. DFlash drafts the whole block in one
    # bidirectional pass; deeper blocks widen the verification batch and add a
    # little draft KV (minor memory).
    --speculative-config "{\"method\":\"dflash\",\"num_speculative_tokens\":15,\"model\":\"${DRAFT_MODEL}\"}"
)

exec bash "$(dirname "$0")/serve.sh" "${args[@]}" "$@"
