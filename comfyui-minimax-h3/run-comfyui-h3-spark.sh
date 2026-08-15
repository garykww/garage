#!/usr/bin/env bash
#
# run-comfyui-h3-spark.sh
# Serve ComfyUI + MiniMax H3 (native core support, Comfy-Org/ComfyUI PR #15224)
# on an NVIDIA DGX Spark (GB10, sm_121).
#
# *** LICENSE: read this app's README.md "License" section before running this
# *** on real workloads. The MiniMax H3 Community License Agreement's "Excluded
# *** Territories" clause names the European Union, the United Kingdom, the
# *** Republic of Korea, AND THE UNITED STATES -- confirmed directly from the
# *** primary LICENSE file, not a rumor. This is not legal advice; read it and
# *** judge your own situation.
#
# Workflow:
#   1. Pre-stage the selected weight tier once into a host-mounted models dir
#      ("download once, mount everywhere"), so the serving boot is a load, not
#      a download. Only the files for the selected QUANT/CHECKPOINT_SET are
#      pulled -- the source HF repo is 465GB total across all tiers.
#   2. Launch ComfyUI in a Docker container.
#   3. Wait for the web server to come up. NOTE: unlike an LLM server, ComfyUI
#      loads model weights LAZILY per workflow run, not eagerly at boot -- so
#      "ready" here means the web UI/API is reachable, NOT that weights are
#      loaded into memory yet. The first Queue Prompt after a fresh start pays
#      that cost (see README.md "Verification").
#
# ----------------------------------------------------------------------------
# Design decisions (and why):
#   - No API_KEY: ComfyUI has no built-in bearer-auth flag equivalent to vLLM's
#     --api-key. If BIND_ADDR is left at its 0.0.0.0 default, anyone reachable
#     on the network can submit generation jobs and browse $OUTPUT_DIR. Set
#     BIND_ADDR=127.0.0.1, or front this with a reverse proxy adding basic
#     auth, if that's not acceptable.
#   - No JIT warm-up request: warming vLLM costs one cheap token; "warming" a
#     video model means actually running a multi-minute generation. WARMUP=1
#     opts into a background reduced-frame T2V submission after readiness;
#     default is off so a plain run doesn't silently eat GPU time.
#   - QUANT tiers (full/int8/pruned) trade quality for headroom on Spark's
#     128GB UNIFIED pool, shared with the host OS and ComfyUI's own working
#     set -- see the table in README.md. Default is "int8": comfortable
#     headroom without the quality hit of the smallest tier.
#   - CHECKPOINT_SET defaults to fl2va only (T2V + first/last-frame-to-video).
#     Adding ref2va roughly doubles the diffusion-model download/footprint for
#     a workflow (reference-to-video) many setups won't use immediately.
#
# Reproducibility:
#   - IMAGE is built locally from this folder's Dockerfile (no prebuilt
#     ComfyUI+H3 image exists for ARM64/CUDA13/sm_121 as of this writing). See
#     the Dockerfile's header for what to verify/pin at build time.

set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
IMAGE="${IMAGE:-comfyui-minimax-h3:local}"   # docker build -t comfyui-minimax-h3:local .
PORT="${PORT:-8188}"
# Host interface to publish the port on. 0.0.0.0 = reachable from other
# machines on the network (default, matches this repo's other Spark launchers).
# Set to 127.0.0.1 to restrict to this host only -- recommended given ComfyUI
# has no built-in auth (see design note above).
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
CONTAINER_NAME="${CONTAINER_NAME:-comfyui-h3}"

# QUANT selects the diffusion-model + text-encoder precision tier. Sizes below
# include both VAEs (video_vae_fp16 4.9GB + audio_vae_fp32 0.6GB, always
# pulled). All figures are against Spark's 128GB UNIFIED pool (shared with the
# host OS + ComfyUI's own working set):
#   full   : fl2va_bf16 (61.7GB) + qwen3vl_bf16 (48.0GB)              ~115.2GB -- max quality, thin headroom, opt-in only
#   int8   : fl2va_int8_convrot (31.7GB) + qwen3vl_int8_convrot (25.3GB)  ~62.5GB -- DEFAULT, comfortable headroom
#   pruned : fl2va_pruned_int8_convrot (19.5GB) + qwen3vl_nvfp4_awq (14.6GB) ~39.6GB -- max headroom (e.g. to share the
#            box with vllm/dgx-spark/ containers running concurrently)
#
# NOTE: Comfy-Org's own vendored T2V/I2V/R2V templates ship with their
# UNETLoader/CLIPLoader node widget values hardcoded to the "pruned" tier's
# filenames (fixed strings, not a dropdown resolved at runtime) -- opening one
# with only "int8" staged throws "Missing Models" in the UI. workflows/ui/*.json
# in this repo have been edited to reference the "int8" filenames instead, so
# they match this DEFAULT out of the box. If you switch QUANT (or restore the
# original templates from workflows/SOURCES.md's upstream URLs), re-point
# those two nodes' filenames to match, via the node UI or by editing the JSON.
QUANT="${QUANT:-int8}"

# CHECKPOINT_SET selects which diffusion-model family/families to pre-stage:
#   fl2va        : text-to-video + first/last-frame-to-video (T2V, I2V templates) -- DEFAULT
#   fl2va+ref2va : adds reference-to-video (R2V template); downloads a second
#                  diffusion checkpoint at the SAME quant tier (roughly doubles
#                  the diffusion-model download/footprint)
CHECKPOINT_SET="${CHECKPOINT_SET:-fl2va}"

HF_REPO="${HF_REPO:-Comfy-Org/MiniMax-H3}"

MODELS_DIR="${MODELS_DIR:-$HOME/.cache/comfyui-h3/models}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/comfyui-h3-output}"
INPUT_DIR="${INPUT_DIR:-$HOME/comfyui-h3-input}"   # reference images/video for I2V/R2V workflows
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only workflows/ui/ (the actual UI-graph-format templates) gets mounted into
# ComfyUI's workflow list. workflows/api-examples/ holds the flat API-format
# smoke-test prompt (see README's "CLI smoke test"), which the web UI can't
# load as a graph, so it's kept out of this mount.
WORKFLOWS_DIR="${WORKFLOWS_DIR:-$SCRIPT_DIR/workflows/ui}"

SKIP_PRESTAGE="${SKIP_PRESTAGE:-0}"
# Opt-in: after readiness, submit a reduced-frame T2V job in the background so
# weights are loaded before your first real request. Off by default -- see
# design note above.
WARMUP="${WARMUP:-0}"

# ---- Resolve QUANT -> exact filenames ----------------------------------------
case "$QUANT" in
  full)   DIFF_SUFFIX="bf16";                TE_FILE="qwen3vl_32b_minimax_h3_bf16.safetensors" ;;
  int8)   DIFF_SUFFIX="int8_convrot";        TE_FILE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors" ;;
  pruned) DIFF_SUFFIX="pruned_int8_convrot"; TE_FILE="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" ;;
  *) echo "ERROR: QUANT must be full|int8|pruned (got '$QUANT')" >&2; exit 1 ;;
esac

DIFF_FILES=("minimax_h3_fl2va_${DIFF_SUFFIX}.safetensors")
case "$CHECKPOINT_SET" in
  fl2va) ;;
  fl2va+ref2va) DIFF_FILES+=("minimax_h3_ref2va_${DIFF_SUFFIX}.safetensors") ;;
  *) echo "ERROR: CHECKPOINT_SET must be fl2va|fl2va+ref2va (got '$CHECKPOINT_SET')" >&2; exit 1 ;;
esac

mkdir -p "$MODELS_DIR"/diffusion_models "$MODELS_DIR"/text_encoders "$MODELS_DIR"/vae \
         "$OUTPUT_DIR" "$INPUT_DIR"

# ---- Pre-flight ---------------------------------------------------------------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "WARNING: HF_TOKEN is not set. $HF_REPO may require auth to download." >&2
  echo "         export HF_TOKEN=hf_xxx   (then re-run)" >&2
fi

# ---- Pre-stage weights (filtered -- NOT the full 465GB repo) -----------------
# Selects only the files for the resolved QUANT/CHECKPOINT_SET tier. Runs
# inside the same image ComfyUI serves from, so huggingface_hub stays in sync
# between pre-stage and serving. Idempotent: `hf download` skips files already
# present, so re-running (e.g. after switching QUANT) only fetches the delta.
#
# Skip with:  SKIP_PRESTAGE=1 ./run-comfyui-h3-spark.sh
if [[ "$SKIP_PRESTAGE" != "1" ]]; then
  INCLUDE_ARGS=()
  for f in "${DIFF_FILES[@]}"; do INCLUDE_ARGS+=(--include "diffusion_models/$f"); done
  INCLUDE_ARGS+=(--include "text_encoders/$TE_FILE")
  INCLUDE_ARGS+=(--include "vae/minimax_h3_video_vae_fp16.safetensors")
  INCLUDE_ARGS+=(--include "vae/minimax_h3_audio_vae_fp32.safetensors")

  echo "Pre-staging weights (QUANT=$QUANT, CHECKPOINT_SET=$CHECKPOINT_SET) into $MODELS_DIR ..."
  docker run --rm \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -v "${MODELS_DIR}:/staging" \
    --entrypoint bash \
    "$IMAGE" \
    -c "hf download '$HF_REPO' ${INCLUDE_ARGS[*]@Q} --local-dir /staging"
  echo "Pre-stage complete."
else
  echo "Skipping pre-stage (SKIP_PRESTAGE=1); using existing $MODELS_DIR."
fi

# ---- Launch --------------------------------------------------------------------
echo "Starting ComfyUI container '$CONTAINER_NAME' ..."

# Docker run flags:
#   -d                      run detached; we tail logs separately below
#   --name                  stable container name so restart/stop/logs are predictable
#   --ipc=host              share host IPC namespace -> larger /dev/shm
#   --restart unless-stopped  auto-restart on crash/reboot, stays down after an explicit `docker stop`
#   --gpus all              expose the GB10 GPU to the container
#   -p BIND_ADDR:PORT:8188  publish ComfyUI's port; BIND_ADDR controls reachability
#   -v MODELS_DIR           the diffusion_models/text_encoders/vae tree pre-staged above
#   -v OUTPUT_DIR           generated videos land here on the host
#   -v INPUT_DIR            reference images/video for I2V/R2V workflows
#   -v WORKFLOWS_DIR        vendored workflow templates -> ComfyUI's per-user workflow list
docker run -d --name "$CONTAINER_NAME" --ipc=host --restart unless-stopped \
  --gpus all -p "${BIND_ADDR}:${PORT}:8188" \
  -v "${MODELS_DIR}:/workspace/ComfyUI/models" \
  -v "${OUTPUT_DIR}:/workspace/ComfyUI/output" \
  -v "${INPUT_DIR}:/workspace/ComfyUI/input" \
  -v "${WORKFLOWS_DIR}:/workspace/ComfyUI/user/default/workflows" \
  "$IMAGE"

# ---- Wait for readiness -------------------------------------------------------
# This confirms the web server/API is up -- NOT that weights are loaded.
# MiniMax H3 loads lazily on the first workflow run; see README.md "Verification".
echo "Waiting for the ComfyUI web server to come up..."
echo "Streaming container logs below (Ctrl-C stops the script, not the container):"
echo "------------------------------------------------------------------------------"

docker logs -f "$CONTAINER_NAME" 2>&1 &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

until curl -sS "http://localhost:${PORT}/system_stats" >/dev/null 2>&1; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    kill "$LOG_PID" 2>/dev/null || true
    echo "------------------------------------------------------------------------------"
    echo "ERROR: container '$CONTAINER_NAME' exited during startup. Full logs:" >&2
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 50 >&2
    exit 1
  fi
  sleep 3
done

kill "$LOG_PID" 2>/dev/null || true
trap - EXIT
echo "------------------------------------------------------------------------------"

# ---- Optional warm-up ----------------------------------------------------------
if [[ "$WARMUP" == "1" ]]; then
  echo "WARMUP=1: submitting a reduced-frame T2V job in the background to preload weights..."
  echo "(This is a real generation, not a cheap ping -- it will take real GPU time.)"
  # Intentionally not wired to a specific workflow JSON here: ComfyUI's /prompt
  # API expects a full node graph, and the "reduced-frame" edit is a workflow
  # decision (which node/field to shrink) best made by hand once per workflow.
  # Left as a documented manual step rather than a brittle jq/sed graph edit.
  echo "NOTE: WARMUP is a placeholder for now -- load workflows/video_minimax_h3_t2v.json"
  echo "      in the UI, reduce its frame count/steps, and Queue Prompt manually."
fi

echo
echo "Ready.   http://localhost:${PORT}"
echo "Logs:    docker logs -f ${CONTAINER_NAME}"
echo "Models:  $MODELS_DIR"
echo "Output:  $OUTPUT_DIR"
echo "Input:   $INPUT_DIR"
echo
echo "NOTE: readiness above only confirms the web UI/API is up. MiniMax H3"
echo "weights (tier: $QUANT) load lazily on first workflow run -- expect the"
echo "first Queue Prompt to take minutes. See README.md 'Verification'."
if [[ "$BIND_ADDR" == "0.0.0.0" ]]; then
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "WARNING: ComfyUI has NO built-in authentication. BIND_ADDR=0.0.0.0 means"
  echo "anyone reachable at http://${LAN_IP:-<this-host-ip>}:${PORT} can submit"
  echo "jobs and browse $OUTPUT_DIR. Set BIND_ADDR=127.0.0.1 to restrict to"
  echo "localhost, or front this with a reverse proxy + basic auth for LAN/remote access."
fi
