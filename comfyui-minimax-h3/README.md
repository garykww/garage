# comfyui-minimax-h3

ComfyUI + [MiniMax H3](https://www.minimax.io/news/minimax-h3-open-source) (native core support,
ComfyUI >= v0.31.0, [`Comfy-Org/ComfyUI#15224`](https://github.com/Comfy-Org/ComfyUI/pull/15224))
on an NVIDIA DGX Spark (GB10, `sm_121`). Text-to-video, image-to-video (first/last-frame), and
reference-to-video, up to 2K/15s with native stereo audio.

## ⚠️ License — read before use

MiniMax H3 ships under the **MiniMax H3 Community License Agreement**. Its
[LICENSE file](https://huggingface.co/MiniMaxAI/MiniMax-H3/raw/main/LICENSE) (confirmed directly
from the primary source, not a secondary summary) defines:

> "Excluded Territories" means the European Union, the United Kingdom, the Republic of Korea **and
> the United States of America.**
>
> You may not use, reproduce, modify, distribute, or display the MiniMax H3 Works or any of their
> Outputs or results outside the Applicable Territory.

The Acceptable Use Policy (Exhibit A) lists "use outside the Applicable Territory" as its first
prohibited use. **This means the license does not grant use rights in the US, EU, UK, or South
Korea.** This is not legal advice — read the license yourself and judge your own situation before
deploying this for real workloads.

## Requirements

- NVIDIA DGX Spark (GB10 / `sm_121`) with the NVIDIA container runtime, Docker with `--gpus all` support
- `HF_TOKEN` (may be required for gated file access on `Comfy-Org/MiniMax-H3`)
- `curl` (readiness check)
- ~40–120GB free disk for weights depending on `QUANT` tier (see below), plus room for generated video output

## Quick start

```bash
# Build the image (see Dockerfile header for what to verify on first build)
docker build -t comfyui-minimax-h3:local .

export HF_TOKEN=hf_xxx
bash run-comfyui-h3-spark.sh
```

```
Ready.   http://localhost:8188
Logs:    docker logs -f comfyui-h3
Models:  ~/.cache/comfyui-h3/models
Output:  ~/comfyui-h3-output
```

Open `http://nv-spark-01:8188` in a browser and open the **Workflows** tab in the left sidebar
(or `Workflow` menu → `Open`). The three vendored templates in `workflows/ui/` (T2V, I2V, R2V)
appear there on first boot — no import step needed, they're mounted straight into ComfyUI's
per-user workflow directory. (`workflows/api-examples/` is deliberately *not* mounted — it holds
a flat API-format prompt for the CLI smoke test below, which isn't a loadable UI graph.)

Examples:

```bash
# Restrict to local access only (recommended — see "No built-in authentication" below)
BIND_ADDR=127.0.0.1 bash run-comfyui-h3-spark.sh

# Lower-footprint tier, e.g. to share the box with a vllm/dgx-spark/ container
QUANT=pruned bash run-comfyui-h3-spark.sh

# Also pull the reference-to-video checkpoint
CHECKPOINT_SET=fl2va+ref2va bash run-comfyui-h3-spark.sh

# Weights already downloaded — skip pre-staging
SKIP_PRESTAGE=1 bash run-comfyui-h3-spark.sh
```

## Configuration

All knobs are environment variables — pass them inline or `export` before running.

| Variable | Default | Description |
|---|---|---|
| `IMAGE` | `comfyui-minimax-h3:local` | built locally from this folder's `Dockerfile` |
| `PORT` | `8188` | host port to publish |
| `BIND_ADDR` | `0.0.0.0` | host interface; `127.0.0.1` restricts to local only (recommended — no built-in auth) |
| `CONTAINER_NAME` | `comfyui-h3` | Docker container name |
| `QUANT` | `int8` | `full` \| `int8` \| `pruned` — diffusion + text-encoder precision tier, see sizing table below |
| `CHECKPOINT_SET` | `fl2va` | `fl2va` (T2V/I2V) \| `fl2va+ref2va` (adds R2V) |
| `HF_REPO` | `Comfy-Org/MiniMax-H3` | HuggingFace source for ComfyUI-reformatted weights |
| `HF_TOKEN` | _(empty)_ | HF token for gated file access |
| `MODELS_DIR` | `~/.cache/comfyui-h3/models` | host path for weights (mounted into the container) |
| `OUTPUT_DIR` | `~/comfyui-h3-output` | host path for generated video |
| `INPUT_DIR` | `~/comfyui-h3-input` | host path for reference images/video (I2V/R2V) |
| `WORKFLOWS_DIR` | `./workflows` | vendored workflow templates |
| `SKIP_PRESTAGE` | `0` | set to `1` to skip weight pre-staging |
| `WARMUP` | `0` | placeholder for a post-readiness warm-up; currently just prints a manual reminder (see script comments) |

## No built-in authentication

Unlike this repo's vLLM launchers (which auto-generate an `API_KEY`), ComfyUI has no equivalent
bearer-auth flag. With the default `BIND_ADDR=0.0.0.0`, **anyone reachable on the network can
submit generation jobs and browse `$OUTPUT_DIR`**. Set `BIND_ADDR=127.0.0.1` to restrict to
localhost, or front the port with a reverse proxy adding basic auth for LAN/remote access.

## Sizing on Spark's 128GB unified pool

Spark's 128GB memory pool is **unified** — shared by the GPU workload, the host OS, and ComfyUI's
own working set. Figures include both VAEs (video 4.9GB + audio 0.6GB, always pulled).

| `QUANT` | Diffusion model | Text encoder | Total (w/ VAEs) | Notes |
|---|---|---|---|---|
| `full` | `minimax_h3_fl2va_bf16` (61.7GB) | `qwen3vl_32b_minimax_h3_bf16` (48.0GB) | ~115.2GB | Max quality, thin headroom — opt-in only |
| `int8` (**default**) | `minimax_h3_fl2va_int8_convrot` (31.7GB) | `qwen3vl_32b_minimax_h3_int8_convrot` (25.3GB) | ~62.5GB | Balanced, comfortable headroom |
| `pruned` | `minimax_h3_fl2va_pruned_int8_convrot` (19.5GB) | `qwen3vl_32b_minimax_h3_nvfp4_awq` (14.6GB) | ~39.6GB | Max headroom — e.g. to run alongside a `vllm/dgx-spark/` container; also the tier Comfy-Org's *upstream* templates ship pre-wired for (see note below) |

**A note on "Missing Models" in the UI:** `UNETLoader`/`CLIPLoader` widget values in a ComfyUI
graph are fixed filenames, not resolved dynamically — they must exactly match a file present in
`models/diffusion_models` / `models/text_encoders`. Comfy-Org's *upstream* T2V/I2V/R2V templates
hardcode the `pruned` tier's filenames, which threw a **"Missing Models"** error against this
recipe's `int8` default (confirmed on nv-spark-01). Rather than switch the default tier, the
templates in `workflows/ui/` here have been **edited to reference the `int8` filenames instead**
(`minimax_h3_fl2va_int8_convrot.safetensors` / `qwen3vl_32b_minimax_h3_int8_convrot.safetensors`,
and `minimax_h3_ref2va_int8_convrot.safetensors` for R2V) — see `workflows/SOURCES.md`. If you
switch `QUANT` to `pruned` or `full`, re-point those two nodes' filenames to match (via the node
UI, or by editing the JSON) or restore the original upstream files.

`CHECKPOINT_SET=fl2va+ref2va` downloads a second diffusion checkpoint at the same tier (roughly
doubles the diffusion-model footprint) to add reference-to-video support.

## Optional: SageAttention

The `Dockerfile` accepts `--build-arg ENABLE_SAGEATTENTION=1` to install SageAttention, which
roughly doubles generation speed. It's **off by default**: there's a known accuracy issue on
sm_120-class Blackwell FP8 PV kernels ([`Comfy-Org/ComfyUI#15263`](https://github.com/Comfy-Org/ComfyUI/issues/15263)),
and Spark's `sm_121` is untested for it. Only enable after validating output quality without it.

## Verification (no unit tests apply here — this is infra)

**Status: validated end-to-end on `nv-spark-01` on 2026-08-15.** Every step below was actually run,
not just described. One real bug was found and fixed in the process: `nvcr.io/nvidia/pytorch:26.07-py3`
does **not** bundle `torchaudio` (only `torch` + `torchvision`) — ComfyUI's audio VAE path
(`comfy/ldm/lightricks/vae/audio_vae.py`) hard-imports it, so the container crash-looped with
`ModuleNotFoundError: No module named 'torchaudio'` on the first attempt. The `Dockerfile` now
builds `torchaudio` from source against the pre-installed torch (see its comments) — this is
already fixed in the file below, not a TODO.

1. `docker manifest inspect nvcr.io/nvidia/pytorch:26.07-py3 | grep -A3 arm64` — **confirmed**: this
   tag does publish an `arm64` manifest, no fallback needed.
2. `docker build -t comfyui-minimax-h3:local .` — check the build log does **not** show
   torch/torchvision being reinstalled (would mean the base image's validated sm_121 build got
   clobbered) — **confirmed clean**; separately confirmed `torchaudio 2.11.0a0+...` builds and
   imports successfully (~85s compile).
3. `docker run --rm --gpus all --entrypoint python3 comfyui-minimax-h3:local -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_capability(), torch.version.cuda)"`
   → **confirmed**: `True (12, 1) 13.3`. (Note the `--entrypoint python3` override — the image's
   default entrypoint is `python3 main.py`, i.e. ComfyUI itself.)
4. Run `run-comfyui-h3-spark.sh` fresh (`SKIP_PRESTAGE=0`) — **confirmed**: pre-stage pulled exactly
   the 4 files for the default `int8` tier, landing at 63GB on disk (matches the ~62.5GB estimate).
5. `docker ps` shows `comfyui-h3` `Up`; `curl http://localhost:8188/system_stats` returns JSON
   listing the GPU — **confirmed**: `ram_total: 130661769216` (the 128GB unified pool), ComfyUI
   `0.33.1`.
6. Search `/object_info` for `MiniMaxH3ImageToVideo`, `MiniMaxH3ReferenceToVideo`,
   `EmptyMiniMaxH3LatentAV`, `MiniMaxH3SigmaShift` — **confirmed all 4 present**, proving the pinned
   ComfyUI tag genuinely includes PR #15224.
7. Load `workflows/ui/video_minimax_h3_t2v.json` in the browser UI (Workflows tab) — **not
   automated from here** (no browser available in this environment); confirmed instead via
   `GET /api/userdata?dir=workflows&recurse=true`, which lists the three mounted files exactly as
   ComfyUI's Workflows tab would see them. Use the CLI smoke test below for a full run without a
   browser — it exercises the identical node pipeline. If you do have a browser handy, loading the
   vendored file directly is still the better check for the full production graph including its
   subgraph wrapper.
8. Queue a reduced generation — **confirmed** via the CLI smoke test below: 52.65s total
   (model load + 8-step sampling at 512×288, 5 frames), diffusion model staged at 32427MB in line
   with the `int8` tier's ~32GB expectation, no OOM.
9. `ffprobe` the output `.mp4` — **confirmed**: `video h264` + `audio aac` streams both present,
   proving the joint video+audio path actually ran.
10. `docker stop comfyui-h3 && docker rm comfyui-h3`, then re-run with `SKIP_PRESTAGE=1` —
    **confirmed**: back up and `Ready.` in ~14s, no re-download.

### CLI smoke test (no browser required)

`workflows/ui/video_minimax_h3_t2v.json` wraps its pipeline in a ComfyUI *subgraph*, which the
`/prompt` API can't execute directly (subgraphs are expanded client-side, in the browser). For a
CLI-only check, use the flat API-format prompt at `workflows/api-examples/smoke_test_api_prompt.json`
instead — same node topology, minimal settings (512×288, 5 frames, 8 steps) for a fast round-trip:

```bash
curl -sS -X POST http://nv-spark-01:8188/prompt \
  -H "Content-Type: application/json" \
  --data @workflows/api-examples/smoke_test_api_prompt.json
# -> {"prompt_id": "...", "number": 0, "node_errors": {}}

# Poll until it completes, then check $OUTPUT_DIR/video/smoke_test_00001_.mp4
curl -sS http://nv-spark-01:8188/history/<prompt_id> | python3 -m json.tool
```

See `workflows/SOURCES.md` for how this file was constructed.

## Container management

```bash
docker logs -f comfyui-h3
docker stop comfyui-h3
docker rm comfyui-h3
```

The container is started with `--restart unless-stopped`, so it survives host reboots but stays
down after an explicit `docker stop`.

## References

- [MiniMax H3 open-source announcement](https://www.minimax.io/news/minimax-h3-open-source)
- [ComfyUI day-0 MiniMax H3 support](https://blog.comfy.org/p/minimax-h3-day-0-support-in-comfyui)
- [MiniMax H3 LICENSE](https://huggingface.co/MiniMaxAI/MiniMax-H3/raw/main/LICENSE)
- [Comfy-Org/MiniMax-H3 weights](https://huggingface.co/Comfy-Org/MiniMax-H3)
- [`vllm/dgx-spark/`](../vllm/dgx-spark/) — sibling app; this recipe's launcher-script pattern (pre-stage → `docker run` → readiness poll) is adapted from there
