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
# This script is the standalone form of spark-control-plane's
# `comfyui-minimax-h3` and `comfyui-minimax-h3-sage` recipes (recipes.yaml).
# It launches the same container the planner does: same image, same flags,
# same host directories, and the same weight files bound read-only out of the
# HuggingFace cache. A container started here and one started from the panel
# share one copy of the weights on disk. If the recipe changes, change this
# script to match.
#
# Workflow:
#   1. Download the recipe's fixed weight set into the HuggingFace cache, once.
#      That's named files, not the whole repo, which holds every quantisation
#      tier and would be ~471 GB.
#   2. Launch ComfyUI in a Docker container, binding each weight file
#      read-only onto the path ComfyUI loads it from.
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
#     on the network can submit generation jobs and browse the output dir. Set
#     BIND_ADDR=127.0.0.1, or front this with a reverse proxy adding basic
#     auth, if that's not acceptable.
#   - No JIT warm-up request: warming vLLM costs one cheap token; "warming" a
#     video model means actually running a multi-minute generation. WARMUP=1
#     opts into a background reduced-frame T2V submission after readiness;
#     default is off so a plain run doesn't silently eat GPU time.
#   - One fixed weight set, not selectable tiers. All eleven files are mounted
#     and appear in ComfyUI's dropdowns; a workflow picks one combination.
#     MOUNTING IS NOT LOADING: an unused tier costs disk, not memory.
#   - --disable-pinned-memory is always passed. See the note at RUN_ARGS.
#
# Reproducibility:
#   - The plain IMAGE is built locally from this folder's Dockerfile (no
#     prebuilt ComfyUI+H3 image exists for ARM64/CUDA13/sm_121 as of this
#     writing). The SageAttention image is published on Docker Hub. See the
#     Dockerfile's header for what to verify/pin at build time.

set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
# On by default: run the SageAttention variant (recipe
# `comfyui-minimax-h3-sage`). Uses that recipe's IMAGE and CONTAINER_NAME
# defaults and passes --use-sage-attention. The flag only works against an
# image built with `--build-arg ENABLE_SAGEATTENTION=1` -- otherwise the
# package isn't installed and startup fails. See the Dockerfile's
# SageAttention comment. Set USE_SAGE_ATTENTION=0 for the plain recipe
# (`comfyui-minimax-h3`), which needs `comfyui-minimax-h3:local` built first.
USE_SAGE_ATTENTION="${USE_SAGE_ATTENTION:-1}"

if [[ "$USE_SAGE_ATTENTION" == "1" ]]; then
  IMAGE="${IMAGE:-garykww/comfyui-minimax-h3:sm121-sage}"
  CONTAINER_NAME="${CONTAINER_NAME:-comfyui-h3-sage}"
else
  IMAGE="${IMAGE:-comfyui-minimax-h3:local}"   # docker build -t comfyui-minimax-h3:local .
  CONTAINER_NAME="${CONTAINER_NAME:-comfyui-h3}"
fi

PORT="${PORT:-8188}"
# Host interface to publish the port on. 0.0.0.0 = reachable from other
# machines on the network (default, matches the recipe). Set to 127.0.0.1 to
# restrict to this host only -- recommended given ComfyUI has no built-in auth
# (see design note above).
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

# Everything ComfyUI writes lives under one host directory, a subfolder per
# kind, the same as the recipe's volumes. Workflows especially: ComfyUI saves
# them inside the container by default, so without this mount anything you
# save dies with the container.
COMFYUI_DIR="${COMFYUI_DIR:-$HOME/Workspace/comfyui}"

# The HuggingFace cache the weights are downloaded into and bound out of --
# the same one spark-control-plane uses, so neither downloads what the other
# already has.
HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}"

SKIP_PRESTAGE="${SKIP_PRESTAGE:-0}"
# Opt-in: after readiness, submit a reduced-frame T2V job in the background so
# weights are loaded before your first real request. Off by default -- see
# design note above.
WARMUP="${WARMUP:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Weights (mirrors the recipe's `weights:` block) --------------------------
# Sizes are decimal GB, measured from the files on nv-spark-01.
HF_REPO="Comfy-Org/MiniMax-H3"                 # 124.6 GB for the seven files below
MODEL_FILES=(
  # The measured default: fl2va int8, and what the ~100 GB memory figure in
  # README.md describes.
  diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors
  text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors
  vae/minimax_h3_video_vae_fp16.safetensors
  vae/minimax_h3_audio_vae_fp32.safetensors
  # 21.0 GB against the 34.0 above, same quantisation. "pruned" compresses the
  # adaLN timestep path only; all 50 transformer blocks are intact.
  diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
  # Reference-to-video, the other task family.
  diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors
  # 15.7 GB against the 27.1 above. The least predictable swap here: NVFP4 AWQ
  # changes the method, not just the precision.
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
)
MODEL_MOUNT_BASE="/workspace/ComfyUI/models"

HF_TURBO_REPO="lightx2v/Minimax-h3-Turbo"      # 7.81 GB for the four LoRAs below
LORA_FILES=(
  # Step-distillation LoRAs: 4-step and 8-step turbo tiers for each task family.
  # A workflow only uses one if it wires a LoraLoaderModelOnly node to it.
  minimax_h3_fl2v_turbo_4step_v1.1_768p_comfyui_bf16.safetensors
  minimax_h3_fl2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors
  minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors
  minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors
)
LORA_MOUNT_BASE="/workspace/ComfyUI/models/loras"

mkdir -p "$COMFYUI_DIR"/input "$COMFYUI_DIR"/output "$COMFYUI_DIR"/workflows \
         "$COMFYUI_DIR"/models/loras "$HF_CACHE"

# ---- Pre-flight ---------------------------------------------------------------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "WARNING: HF_TOKEN is not set. $HF_REPO may require auth to download." >&2
  echo "         export HF_TOKEN=hf_xxx   (then re-run)" >&2
fi

# ---- Pre-stage weights into the HuggingFace cache ----------------------------
# Runs `hf` inside the same image ComfyUI serves from, so the host needs no
# Python. Runs as the calling user so the cache stays owned by them -- the
# control plane's cache panel lists and deletes entries there. Idempotent:
# `hf download` skips files already in the cache.
#
# Skip with:  SKIP_PRESTAGE=1 ./run-comfyui-h3-spark.sh
hf_download() {
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HF_HOME=/hf \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -v "${HF_CACHE}:/hf" \
    --entrypoint hf \
    "$IMAGE" \
    download "$@"
}

if [[ "$SKIP_PRESTAGE" != "1" ]]; then
  echo "Downloading $HF_REPO (${#MODEL_FILES[@]} files, ~124.6 GB) into $HF_CACHE ..."
  hf_download "$HF_REPO" "${MODEL_FILES[@]}"
  echo "Downloading $HF_TURBO_REPO (${#LORA_FILES[@]} files, ~7.8 GB) into $HF_CACHE ..."
  hf_download "$HF_TURBO_REPO" "${LORA_FILES[@]}"
  echo "Pre-stage complete."
else
  echo "Skipping pre-stage (SKIP_PRESTAGE=1); using what is already in $HF_CACHE."
fi

# ---- Resolve cache snapshots -> read-only binds ------------------------------
# The cache addresses a revision by its commit sha, which changes when the repo
# is updated, so read it out of the repo's own refs/main rather than hardcoding
# it. Each file in the snapshot is a symlink to its blob; Docker resolves the
# symlink, so the container sees an ordinary file at the path it expects.
snapshot_dir() {
  local repo_dir="$HF_CACHE/hub/models--${1//\//--}"
  local rev
  rev="$(cat "$repo_dir/refs/main" 2>/dev/null || true)"
  if [[ -z "$rev" ]]; then
    echo "ERROR: $1 is not in the HuggingFace cache at $HF_CACHE. Re-run without SKIP_PRESTAGE=1." >&2
    exit 1
  fi
  printf '%s\n' "$repo_dir/snapshots/$rev"
}

WEIGHT_MOUNTS=()
add_weight_mounts() {   # add_weight_mounts <repo> <mount base> <file>...
  local snap base="$2" f
  snap="$(snapshot_dir "$1")"
  shift 2
  for f in "$@"; do
    if [[ ! -e "$snap/$f" ]]; then
      echo "ERROR: $snap/$f is missing. Re-run without SKIP_PRESTAGE=1." >&2
      exit 1
    fi
    WEIGHT_MOUNTS+=(-v "$snap/$f:$base/$f:ro")
  done
}
add_weight_mounts "$HF_REPO" "$MODEL_MOUNT_BASE" "${MODEL_FILES[@]}"
add_weight_mounts "$HF_TURBO_REPO" "$LORA_MOUNT_BASE" "${LORA_FILES[@]}"

# ---- Seed the workflows directory --------------------------------------------
# The workflows mount is your data, not this repo's. Copy the vendored UI
# templates in only where no file of that name exists, so an edited copy is
# never overwritten.
for f in "$SCRIPT_DIR"/workflows/ui/*.json; do
  dest="$COMFYUI_DIR/workflows/$(basename "$f")"
  [[ -e "$dest" ]] || cp "$f" "$dest"
done

# ---- Launch --------------------------------------------------------------------
echo "Starting ComfyUI container '$CONTAINER_NAME' from $IMAGE ..."

# Docker run flags (the same set spark-control-plane's planner emits):
#   -d                      run detached; we tail logs separately below
#   --name                  stable container name so restart/stop/logs are predictable
#   --restart unless-stopped  auto-restart on crash/reboot, stays down after an explicit `docker stop`
#   --gpus all              expose the GB10 GPU to the container
#   --ipc=host              share host IPC namespace -> past docker's 64MB /dev/shm
#   -p BIND_ADDR:PORT:8188  publish ComfyUI's port; BIND_ADDR controls reachability
#   -v COMFYUI_DIR/...      input, output, saved workflows, and a writable loras/ for LoRAs
#                           dropped in by hand
#   WEIGHT_MOUNTS           each weight file read-only out of the HF cache. The turbo LoRAs
#                           nest inside the writable loras/ mount; Docker applies the more
#                           specific bind on top.
#
# CMD args replace the image's default CMD wholesale, so --listen/--port are
# repeated here.
#
# --disable-pinned-memory stops a failure, not just a slowdown. ComfyUI budgets
# pinned host memory at ~109.5 GB of the 121.7 GiB pool here, counting swap,
# and pinned pages can't be swapped, so as it pins it pushes everything else
# into swap until swap is gone. That is how a 2026-09-06 ref2va run died in
# VAEDecode after 7h19m of sampling ("Enabled pinned memory 112147.0" in the
# log). Measured A/B on 2026-09-12: same speed, identical GPU memory, host
# cgroup peak 42.72 GiB -> 4.83 GiB. See MEMORY_FLAG_BENCHMARKS.md.
#
# Tried and deliberately NOT set (see README.md "Memory flags"): --highvram,
# --use-ck-attention, --disable-mmap, --disable-dynamic-vram, --reserve-vram.
RUN_ARGS=(--listen 0.0.0.0 --port 8188 --disable-pinned-memory)
if [[ "$USE_SAGE_ATTENTION" == "1" ]]; then RUN_ARGS+=(--use-sage-attention); fi

docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
  --gpus all --ipc=host -p "${BIND_ADDR}:${PORT}:8188" \
  -v "${COMFYUI_DIR}/input:/workspace/ComfyUI/input" \
  -v "${COMFYUI_DIR}/output:/workspace/ComfyUI/output" \
  -v "${COMFYUI_DIR}/workflows:/workspace/ComfyUI/user/default/workflows" \
  -v "${COMFYUI_DIR}/models/loras:/workspace/ComfyUI/models/loras" \
  "${WEIGHT_MOUNTS[@]}" \
  "$IMAGE" "${RUN_ARGS[@]}"

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
  echo "NOTE: WARMUP is a placeholder for now -- load video_minimax_h3_t2v.json"
  echo "      in the UI, reduce its frame count/steps, and Queue Prompt manually."
fi

echo
echo "Ready.     http://localhost:${PORT}"
echo "Logs:      docker logs -f ${CONTAINER_NAME}"
echo "Weights:   $HF_CACHE (read-only binds)"
echo "Data:      $COMFYUI_DIR/{input,output,workflows,models/loras}"
echo
echo "NOTE: readiness above only confirms the web UI/API is up. MiniMax H3"
echo "weights load lazily on first workflow run -- expect the first Queue"
echo "Prompt to take minutes. See README.md 'Verification'."
if [[ "$BIND_ADDR" == "0.0.0.0" ]]; then
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo
  echo "WARNING: ComfyUI has NO built-in authentication. BIND_ADDR=0.0.0.0 means"
  echo "anyone reachable at http://${LAN_IP:-<this-host-ip>}:${PORT} can submit"
  echo "jobs and browse $COMFYUI_DIR/output. Set BIND_ADDR=127.0.0.1 to restrict to"
  echo "localhost, or front this with a reverse proxy + basic auth for LAN/remote access."
fi
