# comfyui-minimax-h3

ComfyUI + [MiniMax H3](https://www.minimax.io/news/minimax-h3-open-source) (native core support,
ComfyUI >= v0.31.0, [`Comfy-Org/ComfyUI#15224`](https://github.com/Comfy-Org/ComfyUI/pull/15224))
on an NVIDIA DGX Spark (GB10, `sm_121`). Text-to-video, image-to-video (first/last-frame), and
reference-to-video, up to 2K/15s with native stereo audio.

`run-comfyui-h3-spark.sh` is the standalone form of the `comfyui-minimax-h3` and
`comfyui-minimax-h3-sage` recipes in `spark-control-plane`'s `recipes.yaml`. It launches the same
container the control-plane panel does: same image, same ComfyUI flags, same host directories, and
the same weight files bound read-only out of the HuggingFace cache. If you change one, change the
other to match.

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
- ~133GB free disk in the HuggingFace cache for the weight set (see below), plus room for generated video output

## Quick start

```bash
export HF_TOKEN=hf_xxx
bash run-comfyui-h3-spark.sh
```

By default the script runs the SageAttention variant from the published
`garykww/comfyui-minimax-h3:sm121-sage` image, so there's nothing to build first. See
[SageAttention](#sageattention-on-by-default) for what that trades.

```
Ready.     http://localhost:8188
Logs:      docker logs -f comfyui-h3-sage
Weights:   ~/.cache/huggingface (read-only binds)
Data:      ~/Workspace/comfyui/{input,output,workflows,models/loras}
```

Open `http://nv-spark-01:8188` in a browser and open the **Workflows** tab in the left sidebar
(or `Workflow` menu → `Open`). On each launch the script copies the three vendored templates in
`workflows/ui/` (T2V, I2V, R2V) into `~/Workspace/comfyui/workflows`, skipping any file that's
already there, so your edits to a template are never overwritten. That directory is writable and
is where ComfyUI saves workflows, so anything you save outlives the container.
(`workflows/api-examples/` is deliberately *not* copied — it holds flat API-format prompts for the
CLI smoke test below, which aren't loadable UI graphs.)

Examples:

```bash
# Restrict to local access only (recommended — see "No built-in authentication" below)
BIND_ADDR=127.0.0.1 bash run-comfyui-h3-spark.sh

# The plain recipe, without SageAttention: build the image first, runs as comfyui-h3
# (see Dockerfile header for what to verify on first build)
docker build -t comfyui-minimax-h3:local .
USE_SAGE_ATTENTION=0 bash run-comfyui-h3-spark.sh

# Weights already in the HuggingFace cache — skip the download check
SKIP_PRESTAGE=1 bash run-comfyui-h3-spark.sh
```

## Configuration

All knobs are environment variables — pass them inline or `export` before running.

| Variable | Default | Description |
|---|---|---|
| `USE_SAGE_ATTENTION` | `1` | `1` runs the `comfyui-minimax-h3-sage` recipe and passes `--use-sage-attention`; `0` runs the plain `comfyui-minimax-h3` recipe. Also switches the `IMAGE`/`CONTAINER_NAME` defaults |
| `IMAGE` | `garykww/comfyui-minimax-h3:sm121-sage` (`comfyui-minimax-h3:local` with `USE_SAGE_ATTENTION=0`) | the plain image is built locally from this folder's `Dockerfile` |
| `CONTAINER_NAME` | `comfyui-h3-sage` (`comfyui-h3` with `USE_SAGE_ATTENTION=0`) | Docker container name. The two defaults differ so both variants can exist side by side |
| `PORT` | `8188` | host port to publish |
| `BIND_ADDR` | `0.0.0.0` | host interface; `127.0.0.1` restricts to local only (recommended — no built-in auth) |
| `COMFYUI_DIR` | `~/Workspace/comfyui` | host root for `input/`, `output/`, `workflows/` and `models/loras/` |
| `HF_HOME` | `~/.cache/huggingface` | HuggingFace cache the weights are downloaded into and bound out of |
| `HF_TOKEN` | _(empty)_ | HF token for gated file access |
| `SKIP_PRESTAGE` | `0` | set to `1` to skip the download step; the script still checks every file is in the cache |
| `WARMUP` | `0` | placeholder for a post-readiness warm-up; currently just prints a manual reminder (see script comments) |

The weight set is fixed and isn't configurable here, because it mirrors the recipe. To change it,
edit `MODEL_FILES` / `LORA_FILES` in the script and the recipe's `weights:` block together.

## No built-in authentication

Unlike this repo's vLLM launchers (which auto-generate an `API_KEY`), ComfyUI has no equivalent
bearer-auth flag. With the default `BIND_ADDR=0.0.0.0`, **anyone reachable on the network can
submit generation jobs and browse `~/Workspace/comfyui/output`**. Set `BIND_ADDR=127.0.0.1` to restrict to
localhost, or front the port with a reverse proxy adding basic auth for LAN/remote access.

## Weights

The script downloads only these eleven files into the HuggingFace cache. Pulling the whole
`Comfy-Org/MiniMax-H3` repo would be ~471GB, because it holds every quantisation tier. Each file is
then bound read-only onto the path ComfyUI loads it from. The cache's own blob-and-symlink layout
isn't something ComfyUI can load; Docker follows the snapshot symlink, so the container sees a
plain file. Because this is the same cache `spark-control-plane` uses, a container started by
either one reuses the other's downloads. The control plane's cache panel lists these files and can
delete them, and deleting them removes files a running container is reading.

Sizes are decimal GB, measured from the files on nv-spark-01.

| File | Size | Role |
|---|---|---|
| `diffusion_models/minimax_h3_fl2va_int8_convrot` | 34.0 | T2V / first-last-frame. The measured default |
| `text_encoders/qwen3vl_32b_minimax_h3_int8_convrot` | 27.1 | Text encoder. The measured default |
| `vae/minimax_h3_video_vae_fp16` | 5.3 | Video VAE |
| `vae/minimax_h3_audio_vae_fp32` | 0.6 | Audio VAE |
| `diffusion_models/minimax_h3_fl2va_pruned_int8_convrot` | 21.0 | Smaller fl2va, same quantisation |
| `diffusion_models/minimax_h3_ref2va_pruned_int8_convrot` | 21.0 | Reference-to-video, a separate task family |
| `text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq` | 15.7 | Smaller text encoder |
| `lightx2v/Minimax-h3-Turbo`: fl2v 4-step, fl2v 8-step, ref2v 4-step, ref2v 8-step LoRAs | 7.8 | Step-distillation LoRAs |

**Mounting is not loading.** Every file shows up in ComfyUI's model dropdowns but uses no memory
until a workflow selects it. The extra tiers are alternatives you choose between; they don't add to
the peak.

- **pruned** doesn't remove anything from the transformer: all 50 blocks, hidden size 5376 and 56
  heads are unchanged. It replaces the adaLN timestep path with a rank-8 lookup table covering 1025
  timesteps. That accounts for exactly 12.97B parameters, or 34.0 → 21.0GB at int8. The
  compression applies to a lookup table rather than the generative weights, and it isn't tied to a
  step count.
- **nvfp4_awq** is the one real unknown. It changes the quantisation method (calibrated AWQ instead
  of rotation-plus-int8) as well as the number format, so there's no arithmetic bound on how much
  quality shifts. On the plus side, NVFP4 runs natively on GB10.
- **Turbo LoRAs** do nothing until a workflow wires a `LoraLoaderModelOnly` node to one. Use a
  4-step LoRA unless the output needs the full schedule. Step count is the one cost that scales
  linearly and is free to change.

A LoRA from anywhere else can go in `~/Workspace/comfyui/models/loras`. That directory is a
writable mount, the turbo LoRAs are bound read-only inside it, and anything you drop there appears
in the dropdowns after a restart.

**"Missing Models" in the UI:** `UNETLoader`/`CLIPLoader` widget values in a ComfyUI graph are
fixed filenames that must exactly match a mounted file. The templates in `workflows/ui/` are edited
to point at files in the table above. T2V and I2V use fl2va int8 with the int8 text encoder. R2V
uses ref2va pruned with the int8 text encoder. See `workflows/SOURCES.md`. The flat presets in
`workflows/api-examples/` use the pruned/nvfp4 files and resolve without edits.

## Memory on Spark's unified pool

Spark has one 121.7GiB pool of LPDDR5X, shared by the GPU workload, the host OS and every other
container. Plan for **~100GB** for a ComfyUI run. That's what the recipe reserves, measured on a
GB10 on 2026-08-31 with the fl2va int8 set generating 2K/15s:

```
cgroup peak                  58 GiB   staged host-side copies
nvidia-smi, the same pid     39 GiB   device-resident weights
-> about 104 GB in total, against a 121.7 GiB pool
```

That's well above the ~67GB of weight files. Unified memory causes the gap in two ways:

1. ComfyUI's "offload device: cpu" frees nothing. Offloading the text encoder to system RAM only
   helps when VRAM is separate; on GB10 it's the same memory. The peak is therefore the **sum** of
   the components (text encoder + diffusion model + VAEs), not the largest one.
2. Dynamic VRAM loading keeps a staged host copy *and* a device copy of the same weights, which on
   one physical pool means the same bytes counted twice.

This figure predates `--disable-pinned-memory` (below), which cut the host-side peak by ~38GB on a
draft-preset run. The recipe keeps 100GB as its measured number anyway. Activation memory scales
with output resolution and duration, so a longer or larger generation needs more.

**References cost far more than their output size suggests.** H3 packs text, video, audio and every
reference into *one* sequence and attends over all of it at every step. On 2026-09-06 a ref2va run
at 480×864/15s had two reference images, a 15s reference video and 15s of reference audio. It used
up the whole pool plus all 16GiB of swap, and died in `VAEDecode` after 7h32m with nothing written.
The reference video alone was 62% of the 172,589-token sequence. A ref2va workflow carrying video
references won't fit beside anything else on this box, and may not fit alone. Before running one:

- **Scale reference video to the generation's canvas.** Reference videos ignore the output size and
  get encoded on a forced 768-short-edge canvas, so that 480×864 run carried its reference at
  768×1344. Put an `ImageScale` to the output size ahead of `ref_video` and ComfyUI keeps the
  smaller size. That brings the sequence down to 98,420 tokens and cuts per-step work by 2.84×.
- **Resample references to 24fps.** A 30fps clip is silently truncated to its first `frame_count`
  frames, which is 12s of a 15s reference. Those frames are stretched over the full duration against
  an untruncated soundtrack, so motion drifts out of sync.
- **Price it first.** Sampling cost grows with the square of the sequence length. The run above
  took 1316s per step, or 7h19m for 20 steps.
- **A failed decode needs headroom, not smaller tiles.** The H3 VAE already tiles internally and
  died inside one tile. Restart the container afterwards; the CUDA context doesn't survive the
  failure.

## Memory flags

The script passes `--listen 0.0.0.0 --port 8188 --disable-pinned-memory --use-sage-attention` by
default, or the same without `--use-sage-attention` when `USE_SAGE_ATTENTION=0`. Each matches its
recipe's `command:` exactly. Full
logs for the A/B tests below are in [`MEMORY_FLAG_BENCHMARKS.md`](MEMORY_FLAG_BENCHMARKS.md).

| Flag | Status | Why |
|---|---|---|
| `--disable-pinned-memory` | **Set** | ComfyUI's pinned-memory budget comes to ~109.5GB here and counts swap, but pinned pages can't be swapped out. As pinning grows it pushes everything else into swap until swap runs out. That's how the 2026-09-06 run died (look for `Enabled pinned memory 112147.0` in the log). Measured on 2026-09-12: same speed, identical GPU memory, host cgroup peak **42.72 → 4.83GiB** |
| `--highvram` | Not set | Cuts memory to ~60GB by dropping the staged host copy, but it didn't stop partial unloading and ran slower than the default |
| `--use-ck-attention` | Not set, yet | Probably the biggest speed lever: attention is 89% of the DiT's FLOPs at long sequence lengths, and the 2026-09-06 run reached only ~36 TFLOPS, ~15% of GB10's bf16 peak. It's comfy-kitchen's INT8 SDPA, already in the base image and unrelated to SageAttention's FP8 path. Not validated against a real generation on sm_121 yet |
| `--disable-dynamic-vram` | Not set | Tested alone: 3.24× slower overall, all of it in model loading (a synchronous full load) |
| `--disable-mmap` | Not set | Without a `comfy/utils.py` `copy=False` patch it adds ~35GB of host memory and runs ~27% slower. With the patch it matches plain mmap exactly, so there's no benefit |
| `--reserve-vram 1` | Not set | Reverted together with the two flags above from [luix93/DGX-Spark-ComfyUI](https://github.com/luix93/DGX-Spark-ComfyUI) and never re-tested alone |

## SageAttention (on by default)

`run-comfyui-h3-spark.sh` launches with SageAttention unless you set `USE_SAGE_ATTENTION=0`. The
`Dockerfile` itself still builds without it unless given `--build-arg ENABLE_SAGEATTENTION=1`, so
`comfyui-minimax-h3:local` stays the plain image the other recipe expects.

That build arg compiles SageAttention 2.2.0 from
source (PyPI only goes up to 1.0.6), targeting sm_121 — see the Dockerfile's own comments for why
that's a source build with specific `TORCH_CUDA_ARCH_LIST` values and a runtime dispatch patch,
not a plain `pip install`. Know the trade-off: there's a known accuracy issue on sm_120-class
Blackwell FP8 PV kernels ([`Comfy-Org/ComfyUI#15263`](https://github.com/Comfy-Org/ComfyUI/issues/15263)).
**Verified on `sm_121` (nv-spark-01, 2026-09-08/09)**: finite output, max abs diff ~0.037 vs.
reference attention — expected for a quantized int8/fp8 kernel, not a correctness bug — and an
end-to-end render through this recipe's own `draft` and `quality` presets both succeeded (`draft`
~10% faster; attention is a small share of a 4-step render, so the win is modest there — `quality`
should see more, not precisely measured). Validate output quality on your own generation before
relying on it, and fall back to `USE_SAGE_ATTENTION=0` if it looks wrong.

The build is published on Docker Hub as `garykww/comfyui-minimax-h3:sm121-sage` (`:latest` has the
same digest), so you don't need to build it. That image was rebuilt from this Dockerfile on
2026-09-10 and got a real 22.9MB compiled wheel, passing its import check. Run against the GPU it
gave finite output with max abs diff 0.069, still quantisation noise. No full ComfyUI generation was
re-run on that tag, and no reference-carrying workflow has run with SageAttention at all. To build
it yourself:

```bash
docker build -t comfyui-minimax-h3:sm121-sage --build-arg ENABLE_SAGEATTENTION=1 .
IMAGE=comfyui-minimax-h3:sm121-sage bash run-comfyui-h3-spark.sh
```

Building with `ENABLE_SAGEATTENTION=1` only *installs* the package. `USE_SAGE_ATTENTION` (default
`1`) is what makes the script launch with `--use-sage-attention`. They're separate switches because one is
baked into the image and the other is chosen per run. It also gets its own image tag and container
name, so the plain and sage variants never quietly depend on whichever image was built most
recently.

## Verification (no unit tests apply here — this is infra)

**Status: validated end-to-end on `nv-spark-01` on 2026-08-15.** Every step below was actually run,
not just described. One real bug was found and fixed in the process: `nvcr.io/nvidia/pytorch:26.07-py3`
does **not** bundle `torchaudio` (only `torch` + `torchvision`) — ComfyUI's audio VAE path
(`comfy/ldm/lightricks/vae/audio_vae.py`) hard-imports it, so the container crash-looped with
`ModuleNotFoundError: No module named 'torchaudio'` on the first attempt. The `Dockerfile` now
builds `torchaudio` from source against the pre-installed torch (see its comments) — this is
already fixed in the file below, not a TODO.

> **Earlier layout.** These steps ran against the script as it was on 2026-08-15, which copied a
> `QUANT=int8` tier into `~/.cache/comfyui-h3/models` and mounted that whole directory. The script
> now uses the recipe's HF-cache binds and `--disable-pinned-memory`. The container that layout
> produces is the one `spark-control-plane` has been running on nv-spark-01 (see the benchmarks
> file), but the script itself hasn't been re-run end to end since the change. Steps 4 and 10 would
> now show eleven files, ~132GB, landing in the HuggingFace cache.

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

# Poll until it completes, then check ~/Workspace/comfyui/output/video/smoke_test_00001_.mp4
curl -sS http://nv-spark-01:8188/history/<prompt_id> | python3 -m json.tool
```

See `workflows/SOURCES.md` for how this file was constructed.

## Container management

```bash
docker logs -f comfyui-h3-sage
docker stop comfyui-h3-sage
docker rm comfyui-h3-sage
```

The container is started with `--restart unless-stopped`, so it survives host reboots but stays
down after an explicit `docker stop`. With `USE_SAGE_ATTENTION=0` the container is `comfyui-h3`. Both
publish port 8188, so stop one before starting the other, or give one a different `PORT`.

## References

- [MiniMax H3 open-source announcement](https://www.minimax.io/news/minimax-h3-open-source)
- [ComfyUI day-0 MiniMax H3 support](https://blog.comfy.org/p/minimax-h3-day-0-support-in-comfyui)
- [MiniMax H3 LICENSE](https://huggingface.co/MiniMaxAI/MiniMax-H3/raw/main/LICENSE)
- [Comfy-Org/MiniMax-H3 weights](https://huggingface.co/Comfy-Org/MiniMax-H3)
- [`vllm/dgx-spark/`](../vllm/dgx-spark/) — sibling app; this recipe's launcher-script pattern (pre-stage → `docker run` → readiness poll) is adapted from there
