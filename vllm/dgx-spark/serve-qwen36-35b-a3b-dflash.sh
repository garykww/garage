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
    # it. 0.85 (~109 GB) maximizes the KV pool to reach the 64K context below;
    # the remaining ~19 GB suffices for the host because single-GPU /dev/shm use
    # is small and the 16g shm cap is lazy (not a reservation).
    --gpu-memory-utilization 0.85

    # 64K context. Reachable because fp8 KV (below) ~doubles the per-token cache
    # and GMU 0.85 enlarges the pool: full-precision auto KV only yielded a
    # ~58.6K-token pool (a single request ran out of KV before 128K), whereas
    # fp8 + 0.85 gives ~125K tokens — 64K fits with room for a 2nd stream.
    --max-model-len 65536

    # Spark bandwidth ceiling; >4 concurrent decode streams spikes TTFT
    --max-num-seqs 4

    # z-lab's recommended prefill chunk for this pair: larger chunks raise
    # prefill throughput and give the drafter more context per step, at the cost
    # of an ~8x larger activation working set and potentially higher TTFT under
    # concurrency on bandwidth-bound Spark
    --max-num-batched-tokens 32768

    # fp8 KV ~halves cache bytes/token, ~doubling the KV pool so 64K context fits
    # on the 128 GB unified box. The checkpoint ships no KV scaling factors, so
    # --calculate-kv-scales computes them on the fly during prefill rather than
    # falling back to scale=1.0 (which would risk fp8 overflow / accuracy loss).
    --kv-cache-dtype fp8
    --calculate-kv-scales

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

    # GPUDirect Storage accelerated weight loading — faster cold start from NVMe
    --load-format fastsafetensors

    # DFlash speculative decoding; 15 draft tokens per step is z-lab's
    # recommended block depth for this pair. DFlash drafts the whole block in one
    # bidirectional pass; deeper blocks widen the verification batch and add a
    # little draft KV (minor memory).
    --speculative-config "{\"method\":\"dflash\",\"num_speculative_tokens\":15,\"model\":\"${DRAFT_MODEL}\"}"
)

exec bash "$(dirname "$0")/serve.sh" "${args[@]}" "$@"
