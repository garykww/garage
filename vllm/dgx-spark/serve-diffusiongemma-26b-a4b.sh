#!/usr/bin/env bash
set -euo pipefail

MODEL="RedHatAI/diffusiongemma-26B-A4B-it-NVFP4"

# Default container name for this model; override with CONTAINER_NAME=...
export CONTAINER_NAME="${CONTAINER_NAME:-vllm-dgemma}"

# Diffusion decoding is only implemented in the V2 model runner; without this
# the V1 runner rejects the architecture at startup.
export EXTRA_ENV="VLLM_USE_V2_MODEL_RUNNER=1 ${EXTRA_ENV:-}"

# ---- Agentic flags -----------------------------------------------------------
# DiffusionGemma supports structured tool use and a reasoning channel, but
# neither Google's developer guide nor the RedHatAI card documents vLLM parser
# names for it. It shares Gemma 4's 26B-A4B architecture and reasoning-channel
# format, so we default to the Gemma 4 recipe's parsers + tool chat template.
# UNVERIFIED for this model: on first run, send a request with a tool schema and
# confirm the response contains parsed tool_calls (not inline text).
# The model's bundled chat template is used as-is (no --chat-template override)
# so --default-chat-template-kwargs applies and clients can override per-request;
# set CHAT_TEMPLATE=examples/tool_chat_template_gemma4.jinja only if the bundled
# template's tool formatting turns out broken.
# Disable entirely with AGENTIC=0, or override TOOL_PARSER / REASONING_PARSER.
AGENTIC="${AGENTIC:-1}"
TOOL_PARSER="${TOOL_PARSER:-gemma4}"
REASONING_PARSER="${REASONING_PARSER:-gemma4}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-}"

AGENTIC_FLAGS=()
if [[ "$AGENTIC" != "0" ]]; then
    if [[ -n "$TOOL_PARSER" ]]; then
        AGENTIC_FLAGS+=(--enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER")
    fi
    if [[ -n "$REASONING_PARSER" ]]; then
        AGENTIC_FLAGS+=(--reasoning-parser "$REASONING_PARSER")
    fi
    if [[ -n "$CHAT_TEMPLATE" ]]; then
        AGENTIC_FLAGS+=(--chat-template "$CHAT_TEMPLATE")
    fi
fi

args=(
    "$MODEL"

    # Canonical HF ID so API clients use it in the model field without remapping
    --served-model-name "$MODEL"

    # Required for diffusiongemma's custom modelling code
    --trust-remote-code

    # Diffusion decode denoises blocks bidirectionally rather than token-by-token,
    # which rules out the default paged-attention backends; TRITON_ATTN is the
    # backend that supports it (and is what GB10's heterogeneous head dims force
    # on Gemma-family models anyway)
    --attention-backend TRITON_ATTN

    # Spark bandwidth ceiling; >4 concurrent decode streams spikes TTFT
    --max-num-seqs 4

    # Diffusion sampler config (read from hf config overrides, not CLI flags):
    # entropy_bound stops denoising a block early once per-token entropy drops
    # below the bound (0.1), trading a fixed step count for adaptive early exit
    --hf-overrides '{"diffusion_sampler": "entropy_bound", "diffusion_entropy_bound": 0.1}'

    # Thinking mode on by default for every chat request unless the client
    # overrides it per-request
    --default-chat-template-kwargs '{"enable_thinking": true}'
)

exec bash "$(dirname "$0")/serve.sh" "${args[@]}" ${AGENTIC_FLAGS[@]+"${AGENTIC_FLAGS[@]}"} "$@"
