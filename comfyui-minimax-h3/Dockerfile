# ARM64 + CUDA13 + sm_121 (Blackwell) image for running ComfyUI with native
# MiniMax H3 support (Comfy-Org/ComfyUI PR #15224, merged 2026-08-03) on an
# NVIDIA DGX Spark.
#
# VERIFIED on nv-spark-01 (2026-08-15):
#   1. nvcr.io/nvidia/pytorch:26.07-py3 DOES publish a linux/arm64 manifest --
#      `docker manifest inspect` confirmed it. torch 2.13.0a0+...nv26.07 /
#      cu13.3 / sm_121 all check out inside the built image. If you change
#      NGC_TAG, re-verify with:
#        docker manifest inspect nvcr.io/nvidia/pytorch:${NGC_TAG} | grep -A3 arm64
#      and fall back to nvcr.io/nvidia/cuda:13.0.0-devel-ubuntu24.04 + a
#      CUDA-13 ARM64 PyTorch nightly wheel (download.pytorch.org/whl/nightly/cu130)
#      if the new tag doesn't have one.
#   2. This NGC tag does NOT bundle torchaudio (only torch + torchvision) --
#      confirmed via a runtime ModuleNotFoundError. Built from source below;
#      see that step's comment for why.
#
# VERIFY AT BUILD TIME (not yet reverified after the fix above):
#   3. COMFYUI_REF must be a tag >= v0.31.0. v0.30.0 merged H3 support but
#      shipped known bugs in the int8_convrot VAE path, audio-VAE offload, and
#      EasyCache that v0.31.0+ fixed -- the default weight set in
#      run-comfyui-h3-spark.sh uses int8_convrot. Check
#      https://github.com/Comfy-Org/ComfyUI/releases for the current latest
#      stable tag and bump the ARG below if a newer one exists.

ARG NGC_TAG=26.07-py3
FROM nvcr.io/nvidia/pytorch:${NGC_TAG}

ARG COMFYUI_REF=v0.33.1
ARG ENABLE_SAGEATTENTION=0

# TRIED AND REVERTED, 2026-09-10: unified-memory env vars
# (PYTORCH_NO_CUDA_MEMORY_CACHING, CUDA_MANAGED_FORCE_DEVICE_ALLOC,
# CUDA_MODULE_LOADING=LAZY, OMP_NUM_THREADS) and a comfy/utils.py patch
# (copy=True -> copy=False in the --disable-mmap tensor-load path), both
# sourced from github.com/luix93/DGX-Spark-ComfyUI. Observed SLOWER on
# nv-spark-01 with these in place - not root-caused which one (or the
# combination) is responsible. If revisiting, test them individually rather
# than as a batch, and verify against a real generation before trusting any
# of them.

WORKDIR /workspace

RUN git clone --depth 1 --branch ${COMFYUI_REF} https://github.com/Comfy-Org/ComfyUI.git

WORKDIR /workspace/ComfyUI

# The NGC base image already ships a torch/torchvision build validated against
# this exact CUDA / sm_121 stack (confirmed on nv-spark-01: torch
# 2.13.0a0+...nv26.07, cu13.3). ComfyUI's requirements.txt lists torch/
# torchvision/torchaudio unpinned, which pip would otherwise reinstall from
# PyPI -- silently clobbering the NGC build with a generic wheel that has no
# sm_121 kernels. Strip those lines before installing the rest.
#
# torchaudio is NOT bundled by this NGC tag (verified: ModuleNotFoundError at
# runtime), but ComfyUI's audio VAE path (comfy/ldm/lightricks/vae/audio_vae.py)
# hard-imports it -- required, not optional, once MiniMax H3's audio VAE loads.
# No prebuilt torchaudio wheel exists for this NVIDIA-custom torch build, so
# build it from source against the already-installed torch. The ffmpeg dev
# libs let torchaudio build its ffmpeg IO backend too (used for encoding H3's
# stereo audio output); if unavailable, torchaudio's setup.py degrades
# gracefully and skips that extension rather than failing the whole build.
RUN grep -vE '^(torch|torchvision|torchaudio)(\b|==|>=)' requirements.txt > requirements.filtered.txt \
    && pip install --no-cache-dir -r requirements.filtered.txt

ARG TORCHAUDIO_REF=main
RUN apt-get update && apt-get install -y --no-install-recommends \
      libavformat-dev libavcodec-dev libavutil-dev libswresample-dev libswscale-dev \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --no-build-isolation \
      "git+https://github.com/pytorch/audio.git@${TORCHAUDIO_REF}" \
    && python3 -c "import torchaudio; print('torchaudio', torchaudio.__version__)"

# Used both by this image's own entrypoint context and by
# run-comfyui-h3-spark.sh's pre-stage step, which runs
# `docker run --rm --entrypoint hf "$IMAGE" download ...` against this same
# image -- keeps the huggingface_hub version consistent between pre-stage and
# serving.
RUN pip install --no-cache-dir -U "huggingface_hub[cli]"

# Optional, OFF by default: SageAttention roughly doubles generation speed but
# has a known accuracy issue on sm_120-class Blackwell FP8 PV kernels
# (Comfy-Org/ComfyUI#15263). VERIFIED on sm_121 (nv-spark-01, 2026-09-08/09):
# finite output, max abs diff ~0.037 vs. reference attention -- expected for a
# quantized int8/fp8 kernel, not a correctness bug. Still opt-in: only enable
# after validating output quality on your own real generation.
#
# PyPI's `sageattention` only goes up to 1.0.6 -- 2.2.0 exists solely as a git
# tag, so it's a source build, not `pip install sageattention==2.2.0`.
# SageAttention's setup.py whitelists SUPPORTED_ARCHS = {"8.0", "8.6", "8.9",
# "9.0", "12.0"} -- sm_121's own "12.1" isn't in that set and gets silently
# dropped (the wheel "succeeds" at ~3MB but compiles no kernels at all, then
# raises `AssertionError: SM89 kernel is not available` on first call). "8.9"
# unlocks the fp8 kernel infrastructure the sm_120/sm_121 path depends on;
# "12.0" is the actual sm_120/sm_121 kernel -- together they produce a real
# ~23MB wheel.
#
# Compiling for 12.0 still isn't enough: sageattn()'s runtime dispatcher in
# core.py checks the *detected* arch string and only has a branch for the
# literal "sm120" -- GB10 reports "sm121" (get_cuda_arch_versions()), so it
# falls through to `ValueError: Unsupported CUDA architecture` even though the
# right kernel was just built. Patched below to route sm121 through the same
# sageattn_qk_int8_pv_fp8_cuda(...) call as sm120 -- same Blackwell
# tensor-core generation, and the base image's own
# `TORCH_CUDA_ARCH_LIST=...12.0+PTX` env var confirms the driver's PTX JIT
# fallback makes an sm_120-targeted cubin safe to run on sm_121 hardware.
#
# Better long-term fix than patching post-install: fork/vendor
# thu-ml/SageAttention, add "12.1" to SUPPORTED_ARCHS and a proper (not
# shared) sm121 branch in core.py, and build from that fork instead -- in case
# NVIDIA ships a genuinely different fp8 tile config for GB10 later.
ARG SAGEATTENTION_REF=v2.2.0
RUN if [ "$ENABLE_SAGEATTENTION" = "1" ]; then \
      TORCH_CUDA_ARCH_LIST='8.9;12.0' pip install --no-cache-dir --no-build-isolation \
        "git+https://github.com/thu-ml/SageAttention.git@${SAGEATTENTION_REF}" \
      && CORE=/usr/local/lib/python3.12/dist-packages/sageattention/core.py \
      && [ "$(grep -c 'elif arch == "sm120":' "$CORE")" = "1" ] \
      && sed -i 's/elif arch == "sm120":/elif arch in ("sm120", "sm121"):/' "$CORE" \
      && python3 -c "import sageattention; print('sageattention imported OK')" \
    ; fi

RUN mkdir -p models/diffusion_models models/text_encoders models/vae models/loras \
    input output user/default/workflows

EXPOSE 8188

# Container-internal port/bind are fixed; host exposure is controlled entirely
# by run-comfyui-h3-spark.sh's `-p BIND_ADDR:PORT:8188`.
ENTRYPOINT ["python3", "main.py"]
CMD ["--listen", "0.0.0.0", "--port", "8188"]
