#!/usr/bin/env bash
#
# serve.sh — Docker-based vllm serve wrapper for DGX Spark.
#
# Usage: bash serve.sh <model> [vllm flags...]
#
# `vllm serve` is prepended automatically inside the docker run command;
# do NOT include it in the arguments passed to this script.
#
# Script-level env vars (not forwarded to vLLM):
#   IMAGE          vLLM Docker image      (default: ghcr.io/spark-arena/dgx-vllm-eugr-nightly)
#   CONTAINER_NAME Docker container name  (default: vllm-serve)
#   PORT           Host port              (default: 8000; maps to container-internal 8000)
#   BIND_ADDR      Host bind address      (default: 0.0.0.0)
#   API_KEY        Bearer token; auto-generated if unset (endpoint never unauthenticated)
#   HF_TOKEN       HuggingFace token for gated models
#   HF_CACHE       Host HF weight cache   (default: ~/.cache/huggingface)
#   VLLM_CACHE     Host torch.compile cache (default: ~/.cache/vllm); persisted across
#                  restarts so the compile is paid once, not every boot
#   SKIP_PRESTAGE  Set to 1 to skip weight pre-staging (weights already cached)

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <model> [vllm serve flags...]" >&2
    exit 1
fi

MODEL="$1"
IMAGE="${IMAGE:-ghcr.io/spark-arena/dgx-vllm-eugr-nightly}"
SHM_SIZE="${SHM_SIZE:-}"  # e.g. 16g; if unset, falls back to --ipc=host
CONTAINER_NAME="${CONTAINER_NAME:-vllm-serve}"
PORT="${PORT:-8000}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
VLLM_CACHE="${VLLM_CACHE:-$HOME/.cache/vllm}"
SKIP_PRESTAGE="${SKIP_PRESTAGE:-0}"

# API key: auto-generate if not set so the endpoint is never unauthenticated.
# Pin API_KEY=... across restarts for a stable key.
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

# ---- Pre-stage weights -------------------------------------------------------
# Download into the host-mounted HF cache before starting the server, so boot
# is a load, not a download. Idempotent: already-cached files are skipped.
mkdir -p "$HF_CACHE" "$VLLM_CACHE"
if [[ "$SKIP_PRESTAGE" != "1" ]]; then
    echo "==> Pre-staging weights: $MODEL"
    docker run --rm \
        -e HF_TOKEN="${HF_TOKEN:-}" \
        -e MODEL="$MODEL" \
        -v "${HF_CACHE}:/root/.cache/huggingface" \
        --entrypoint bash \
        "$IMAGE" \
        -c 'if command -v hf >/dev/null 2>&1; then hf download "$MODEL"; else huggingface-cli download "$MODEL"; fi'
    echo "==> Pre-stage complete."
fi

# ---- Launch ------------------------------------------------------------------
# Remove any existing container with the same name so docker run doesn't conflict.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "==> Removing existing container '$CONTAINER_NAME'..."
    docker rm -f "$CONTAINER_NAME"
fi

echo "==> Starting container '$CONTAINER_NAME': $MODEL"

# docker run flags:
#   -d                       run detached; logs tailed separately during the wait
#   --ipc=host / --shm-size  vLLM needs large /dev/shm for tensor/IPC transfer;
#                            use SHM_SIZE=16g for an explicit cap, or leave unset
#                            to share the full host IPC namespace (--ipc=host)
#   --restart unless-stopped survive reboots, stay down after explicit docker stop
#   --gpus all               expose GB10 to the container
#   -p BIND_ADDR:PORT:8000   publish container-internal port 8000 on the host
#   -v HF_CACHE              weight cache mounted read-write (download once, reuse)
#   -v VLLM_CACHE            torch.compile cache persisted across restarts
IPC_FLAGS=()
if [[ -n "$SHM_SIZE" ]]; then
    IPC_FLAGS=(--shm-size="$SHM_SIZE")
else
    IPC_FLAGS=(--ipc=host)
fi

docker run -d \
    --name "$CONTAINER_NAME" \
    "${IPC_FLAGS[@]}" \
    --restart unless-stopped \
    --gpus all \
    -p "${BIND_ADDR}:${PORT}:8000" \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -v "${HF_CACHE}:/root/.cache/huggingface" \
    -v "${VLLM_CACHE}:/root/.cache/vllm" \
    "$IMAGE" \
    vllm serve \
    "$@" \
    --api-key "$API_KEY"

# ---- Wait for readiness ------------------------------------------------------
AUTH_HEADER="Authorization: Bearer ${API_KEY}"
echo "==> Waiting for server (weight load may take several minutes)..."
echo "==> Streaming container logs (Ctrl-C stops script, not container):"
echo "---"

docker logs -f "$CONTAINER_NAME" 2>&1 &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

until curl -sf -H "$AUTH_HEADER" "http://localhost:${PORT}/v1/models" > /dev/null 2>&1; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        kill "$LOG_PID" 2>/dev/null || true
        echo "---"
        echo "ERROR: container '$CONTAINER_NAME' exited during startup." >&2
        docker logs "$CONTAINER_NAME" 2>&1 | tail -n 50 >&2
        exit 1
    fi
    sleep 5
done

kill "$LOG_PID" 2>/dev/null || true
trap - EXIT
echo "---"

# ---- Pre-warm the JIT -------------------------------------------------------
# Fire a small request so the first real user request doesn't eat cold-start JIT.
SERVED_MODEL="$MODEL"
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--served-model-name" ]]; then
        SERVED_MODEL="${args[$((i+1))]}"
        break
    fi
done

echo "==> Pre-warming JIT (3-token chat completion)..."
curl -sf "http://localhost:${PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -d "{\"model\":\"$SERVED_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" \
    > /dev/null \
    && echo "==> Warm-up done." \
    || echo "WARN: Warm-up failed (non-fatal)"

echo
echo "Ready.    http://localhost:${PORT}/v1"
echo "Metrics:  http://localhost:${PORT}/metrics"
echo "Logs:     docker logs -f ${CONTAINER_NAME}"
echo

if [[ "$API_KEY_GENERATED" == "1" ]]; then
    echo "API key (auto-generated): ${API_KEY}"
    echo "  Pin with API_KEY=... to keep stable across restarts."
else
    echo "API key: (provided via API_KEY)"
fi
echo "  Clients: Authorization: Bearer ${API_KEY}"

if [[ "$BIND_ADDR" == "0.0.0.0" ]]; then
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "Network:  http://${LAN_IP:-<this-host-ip>}:${PORT}/v1"
fi
