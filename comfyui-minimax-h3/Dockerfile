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
#      EasyCache that v0.31.0+ fixed -- the default QUANT tier in
#      run-comfyui-h3-spark.sh uses int8_convrot. Check
#      https://github.com/Comfy-Org/ComfyUI/releases for the current latest
#      stable tag and bump the ARG below if a newer one exists.

ARG NGC_TAG=26.07-py3
FROM nvcr.io/nvidia/pytorch:${NGC_TAG}

ARG COMFYUI_REF=v0.33.1
ARG ENABLE_SAGEATTENTION=0

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
# `docker run --rm --entrypoint bash "$IMAGE" -c 'hf download ...'` against
# this same image -- keeps the huggingface_hub version consistent between
# pre-stage and serving.
RUN pip install --no-cache-dir -U "huggingface_hub[cli]"

# Optional, OFF by default: SageAttention roughly doubles generation speed but
# has a known accuracy issue on sm_120-class Blackwell FP8 PV kernels
# (Comfy-Org/ComfyUI#15263). sm_121 (Spark) is untested for this bug -- only
# enable after validating output quality on a real generation without it.
RUN if [ "$ENABLE_SAGEATTENTION" = "1" ]; then pip install --no-cache-dir sageattention; fi

RUN mkdir -p models/diffusion_models models/text_encoders models/vae \
    input output user/default/workflows

EXPOSE 8188

# Container-internal port/bind are fixed; host exposure is controlled entirely
# by run-comfyui-h3-spark.sh's `-p BIND_ADDR:PORT:8188`.
ENTRYPOINT ["python3", "main.py"]
CMD ["--listen", "0.0.0.0", "--port", "8188"]
