# dgx-spark

vLLM launch scripts for NVIDIA DGX Spark (GB10, `sm_121`), with OpenAI-compatible endpoints ready for agentic / tool-calling workloads.

| Script | Model | Notes |
|---|---|---|
| `run-gemma4-26b-a4b-spark.sh` | `nvidia/Gemma-4-26B-A4B-NVFP4` | Docker-based, HF-hosted weights, agentic tool calling |
| `serve-qwen36-35b-a3b-dflash.sh` | `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | Docker-based, DFlash speculative decoding |
| `serve-diffusiongemma-26b-a4b.sh` | `RedHatAI/diffusiongemma-26B-A4B-it-NVFP4` | Docker-based, diffusion decoding (V2 model runner) |
| `serve-qwen38-27b-mtp.sh` | `unsloth/Qwen3.8-27B-NVFP4` | Docker-based, dense hybrid-attention VLM, built-in MTP speculative decoding |
| `serve-qwen38-27b-sglang.sh` | `RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead` | **SGLang** engine, same model — GB10-tuned GDN pool, FP8 KV, MTP or DSpark drafting, YaRN to 1M |

---

## Qwen3.8-27B (MTP)

> There is now an **SGLang** recipe for this same model — see
> [Qwen3.8-27B (SGLang)](#qwen38-27b-sglang). It is faster on code and carries the
> GB10-specific tuning; this vLLM script remains the lighter-footprint option for
> sharing the box.

**unsloth/Qwen3.8-27B-NVFP4** — a dense, hybrid-attention (linear attention on 48 of 64 layers), natively multimodal (vision-capable) model with a built-in Multi-Token Prediction (MTP) draft head baked into the checkpoint, 262,144-token native context, and NVFP4 weights that fit a single Blackwell GPU at ~24.6 GiB.

The launcher (`serve-qwen38-27b-mtp.sh`) is self-contained and handles:

1. **Pre-staging** the NVFP4 weights into a host-mounted HF cache (download once, reuse across restarts) — no separate draft model to stage, since MTP's draft head ships inside the checkpoint (unlike the Qwen3.6 DFlash recipe above)
2. **Launching vLLM** in a Docker container with all recommended flags pre-set, tuned for Spark's unified-memory profile
3. **Waiting for readiness**, streaming container logs while the safetensor load completes
4. **Pre-warming the JIT** so the first real request doesn't eat cold-start compilation

### Image

Default image: `ghcr.io/spark-arena/dgx-vllm-eugr-nightly` (same patched DGX Spark build used by the other scripts in this folder; its entrypoint is not `vllm serve`, so the launcher prepends it).

### Requirements

- NVIDIA DGX Spark (GB10 / `sm_121`) with the NVIDIA container runtime
- Docker with `--gpus all` support
- `HF_TOKEN` set (gated models)
- `curl` and `jq` (readiness check and warm-up)

### Quick start

```bash
export HF_TOKEN=hf_xxx
bash serve-qwen38-27b-mtp.sh
```

```
Ready.    http://localhost:8000/v1
Metrics:  http://localhost:8000/metrics
Logs:     docker logs -f vllm-qwen38
```

Examples:

```bash
BIND_ADDR=127.0.0.1 API_KEY=sk-mykey bash serve-qwen38-27b-mtp.sh
SKIP_PRESTAGE=1 bash serve-qwen38-27b-mtp.sh
KV_CACHE_DTYPE=fp8 bash serve-qwen38-27b-mtp.sh   # larger KV pool, more concurrency/context headroom
```

### Performance notes (measured on a single DGX Spark, per the [NVIDIA developer forum writeup](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-a-single-dgx-spark-up-to-1m-context-vllm-mtp-measurements/380244))

Memory budget on the 128 GB **unified** pool at `gpu-memory-utilization=0.45`: weights + overhead ~26.16 GiB, peak activation ~1.80 GiB, KV cache ~27.56 GiB — supporting ~777,645 KV tokens (~2.97x concurrency) at the **full native 262K context**, so unlike the Qwen3.6 script above, context does not need to be scaled down for the shared-box default.

- `gpu-memory-utilization=0.45` — sized to share the 128 GB pool with a second model side-by-side, matching this folder's other recipes. Raise toward 0.85 to run this model alone with more concurrency, or ~0.60 to unlock YaRN scaling toward the model's 1M-token extended context (6.6M KV tokens reported at that scale on Blackwell — needs additional rope-scaling config beyond this launcher's defaults; see the vLLM recipe page below).
- `kv-cache-dtype=auto` (default) — the measured-working Spark config used full-precision KV; this NVFP4 community quant, like the Gemma 4 checkpoint above, ships no fp8 KV scaling factors. `KV_CACHE_DTYPE=fp8` roughly doubles the KV pool and the launcher adds `--calculate-kv-scales` automatically in that case.
- `max-num-seqs=4`, `max-num-batched-tokens=8192` — the exact concurrency / prefill-chunk pair measured working on a single Spark for this model.
- `num_speculative_tokens=5` (MTP) — measured working on Spark; [vLLM's own recipe page](https://recipes.vllm.ai/Qwen/Qwen3.8-27B) suggests 3 as a lighter starting point. Reported decode throughput with MTP: ~24.7 tok/s, TTFT ~0.3s; prefill ranges ~1,734 tok/s at 4.5K tokens down to ~853 tok/s at 48K tokens.
- Tool/reasoning parsers: `qwen3_coder` / `qwen3` per vLLM's own recipe page. The forum's Spark deployment instead used `qwen3_xml` for tool calls — if tool calls come back unparsed, try `TOOL_PARSER=qwen3_xml`.

**Known issue (fixed upstream):** early copies of the `unsloth/Qwen3.8-27B-NVFP4` tokenizer silently truncated prompts at 2048 tokens. If long-context requests come back truncated, re-pull the checkpoint and check `tokenizer_config.json` for `"truncation": null`.

### Container management

```bash
docker logs -f vllm-qwen38
docker stop vllm-qwen38
docker rm vllm-qwen38
```

---

## Qwen3.8-27B (SGLang)

Same model as the section above, different engine. `serve-qwen38-27b-sglang.sh`
runs Qwen3.8-27B on **SGLang** instead of vLLM, because that is where the
GB10-specific tuning for this architecture actually exists: the hybrid gated
delta net (48 linear-attention layers + 16 full-attention) needs its recurrent
state pool sized by hand, and SGLang exposes the knobs to do it.

The flag stack follows
[MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark),
which starts from the [SGLang cookbook's DGX Spark cell](https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B)
and then pins each choice against on-device measurement rather than guesswork.

### Quick start

```bash
export HF_TOKEN=hf_xxx
bash serve-qwen38-27b-sglang.sh                 # MTP drafting (default)
SPEC_MODE=dspark bash serve-qwen38-27b-sglang.sh  # DSpark drafting — much faster on code
```

Serves on port **8000**, the same port the vLLM scripts in this folder use, so
only one of them can be up at a time. Stop the vLLM container first
(`docker stop vllm-qwen38`), or pass `PORT=8888` to run both side by side.

### Which drafter

Upstream's measured numbers, on their Spark. Code and essay are `bench/ndec.py`
net-decode, n=5; DSpark/MTP measured 2026-08-18, DFlash2 2026-08-19.

| Probe | DSpark (block-7) | MTP (EAGLE 3/1/4) |
|---|---|---|
| Code — LRUCache + small test | **51.5 tok/s** | 34.5 tok/s |
| Long essay — Babbage → GPUs | 18.3 tok/s | **24.1 tok/s** |

**DSpark for code, agents, and tool calls; MTP for long-form prose.** DSpark is
~1.5x on the code probe and gives roughly a quarter of the essay rate back.

Read those as indicative, not a race: the two columns come from different days,
and upstream treats code deltas under 15% as noise within a session. MTP costs
no extra download (the draft head is in the checkpoint); DSpark pulls a separate
~2.7 GB drafter. Upstream's step sweep confirms 3/1/4 is the MTP peak here
(2 → 12.8, 3 → 17.2, 4 → 16.8, 5 → 16.3, 6 → 15.8 tok/s).

Upstream also supports a third drafter, DFlash2, which needs a derived image
built from their `patch/` tree — not wired into this script. Use their repo if
you want it.

### How this differs from the vLLM script

| | `serve-qwen38-27b-mtp.sh` (vLLM) | `serve-qwen38-27b-sglang.sh` (SGLang) |
|---|---|---|
| Checkpoint | `unsloth/Qwen3.8-27B-NVFP4` | `RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead` |
| Memory | `--gpu-memory-utilization 0.45` (shares the box) | `--mem-fraction-static 0.95` (claims it) |
| KV cache | `auto`, full precision | `fp8_e4m3` |
| Port | 8000 | 8000 (same — one at a time) |

Two things worth calling out, because they contradict the section above:

- **The checkpoint is different, deliberately.** The RadixArk export is what the
  cookbook recipes were measured against, and it never had the 2048-token
  tokenizer truncation bug documented in the MTP section. `QUANT=nvfp4-fp4`
  selects the packed-FP4-head twin (~22 GB vs ~24 GB).
- **KV precision flips.** The vLLM script runs full-precision KV because the
  unsloth export ships no FP8 KV scales. The RadixArk checkpoint *declares*
  `kv_cache_quant_algo: FP8` and ships calibration scales, so this script sets
  `--kv-cache-dtype fp8_e4m3` explicitly. ~32.8 KB/token — a full 1M-token
  sequence is ~33 GB of KV.

**This script defaults to claiming nearly the whole 128 GB pool** (`0.95`, or
`0.90` with a drafter loaded), unlike this folder's other recipes which default
to `0.45` to leave room for a second model. Lower `MEM_FRACTION_STATIC` if you
are sharing the box.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `QUANT` | `nvfp4` | `nvfp4` (BF16 head) · `nvfp4-fp4` (packed FP4 head) · `fp8` · `bf16` |
| `SPEC_MODE` | `mtp` | `mtp` · `dspark` · `none` |
| `PORT` | `8000` | Shared with the vLLM scripts; set `8888` to run both at once |
| `HOST_BIND` | `0.0.0.0` | SGLang `--host`; `127.0.0.1` restricts to this box |
| `CONTEXT_LENGTH` | `262144` | Native; up to `1000000` with `YARN=1` |
| `YARN` | `0` | Rope scaling, required above native context. **MTP only** |
| `MAX_CONCURRENT_REQUESTS` | `10` | Also sizes the GDN state pool (× 4 slots) |
| `MEM_FRACTION_STATIC` | `0.95` / `0.90` | 0.90 when `SPEC_MODE=dspark` |
| `ATTENTION_BACKEND` | `flashinfer` | Required on sm_121; `triton` is the fallback |
| `CHUNKED_PREFILL` | `8192` | 2048 smooths inter-token latency at some prefill cost |
| `CPUSET` | `5-9,15-19` | GB10's Cortex-X5 cores; `""` disables pinning |
| `MAMBA_SKIP_DECODE_LOCK` | `0` | `1` frees one GDN slot per request (S 4 → 3) |
| `PREFILL_CUDA_GRAPH` | `0` | `1` re-enables prefill CUDA graphs |
| `DSPARK_BLOCK_SIZE` | `7` | Code peak; `5` trades −16% code for +8% prose |
| `PRIVILEGED` | `0` | Upstream runs `--privileged`; opt in if boot needs it |
| `EXTRA_ARGS` | _(empty)_ | Appended last; argparse last-wins |

### Why the odd-looking flags

- **`--attention-backend flashinfer` is mandatory on GB10.** The cookbook's
  `trtllm_mha` is SM100-only and will not run on sm_121.
- **GDN state pool.** `--mamba-full-memory-ratio 4.21` replaces the `0.9`
  default, which over-provisions KV and silently clamps concurrency.
  `--max-mamba-cache-size` is pinned to `concurrency × 4` — speculative verify
  states live in a *separate* buffer, so folding draft tokens in over-provisions
  the pool 2x. `--mamba-ssm-dtype bfloat16` keeps a slot at 78.4 MB against the
  fp32 default's 153.9 MB.
- **`--max-running-requests` is pinned** because speculative decoding otherwise
  resets it to 48 behind your back. The script greps the boot log and prints the
  cap it actually got, so you can see if it stuck.
- **CPU pinning matters here.** GB10 is big.LITTLE; without `--cpuset-cpus` the
  scheduler and tokenizer land on the 2.8 GHz A725 cores about half the time.
  Measured +2–7% decode upstream.

### Gotchas

- **YaRN is MTP-only.** Above 262K the rope override leaks into the draft
  model's config and crashes the rope validator (`AttributeError: …
  max_position_embeddings`). The script refuses `YARN=1` with `SPEC_MODE=dspark`
  rather than letting you find out at boot.
- **Don't run a drafter at `0.95`.** Upstream hard-rebooted the box that way.
  The script drops to `0.90` automatically for `SPEC_MODE=dspark`.
- **Spec decode erroring at boot?** Retry with `ATTENTION_BACKEND=triton`.
- Thinking is **on by default**; disable per request with
  `chat_template_kwargs: {"enable_thinking": false}`. Tool calling needs no
  vLLM-style `--enable-auto-tool-choice` — just send `tools`.

### Container management

```bash
docker logs -f sglang-qwen38
docker stop sglang-qwen38
docker rm sglang-qwen38
```

---

## Qwen3.6-35B-A3B-NVFP4 (DFlash)

**RedHatAI/Qwen3.6-35B-A3B-NVFP4** with DFlash speculative decoding via **z-lab/Qwen3.6-35B-A3B-DFlash**.

The launcher (`serve-qwen36-35b-a3b-dflash.sh`) is self-contained and handles:

1. **Pre-staging** both the target weights and the DFlash draft model into a host-mounted HF cache (download once, reuse across restarts)
2. **Launching vLLM** in a Docker container with all recommended flags pre-set, tuned for Spark's unified-memory profile
3. **Waiting for readiness**, streaming container logs while the safetensor load completes
4. **Pre-warming the JIT** so the first real request doesn't eat cold-start compilation

### Image

DFlash (`method: dflash` in `--speculative-config`) is native upstream vLLM — no custom patches needed. Default image: `ghcr.io/spark-arena/dgx-vllm-eugr-nightly`.

### Requirements

- NVIDIA DGX Spark (GB10 / `sm_121`) with the NVIDIA container runtime
- Docker with `--gpus all` support
- `HF_TOKEN` set (gated models)
- `curl` (readiness check and warm-up)

### Quick start

```bash
export HF_TOKEN=hf_xxx
bash serve-qwen36-35b-a3b-dflash.sh
```

```
Ready.    http://localhost:8000/v1
Metrics:  http://localhost:8000/metrics
Logs:     docker logs -f vllm-qwen36
```

Examples:

```bash
BIND_ADDR=127.0.0.1 API_KEY=sk-mykey bash serve-qwen36-35b-a3b-dflash.sh
SKIP_PRESTAGE=1 bash serve-qwen36-35b-a3b-dflash.sh
```

### Performance notes (DGX Spark, GB10)

Memory budget on the 128 GB **unified** pool (shared by the GPU's `gpu-memory-utilization` fraction, the container's `/dev/shm`, and the host OS): NVFP4 target weights ~20 GB, the **0.5B DFlash drafter ~1 GB**, the rest of the fraction is KV cache. The defaults below are sized to **share the box with a second model side-by-side**; override them to run this model alone (see the examples above).

- `gpu-memory-utilization=0.45` — vLLM loads the target weights, the DFlash drafter, **and** the KV cache all *inside* this fraction; the drafter and its KV contend with the target KV cache here, they are not allocated outside it. 0.45 (~58 GB) is sized so two models fit the 128 GB pool (2 × ~0.45 leaves host headroom), leaving a ~36 GB KV pool. Raise toward 0.85 (~109 GB) to run this model alone with a larger context.
- `kv-cache-dtype=fp8` + `calculate-kv-scales` — fp8 ~halves KV bytes/token, ~doubling the pool so 32K fits in the reduced fraction. The checkpoint ships no KV scales, so `--calculate-kv-scales` computes them on the fly during prefill instead of falling back to `scale=1.0` (which risks fp8 overflow / accuracy loss).
- `max-model-len=32768` — 32K, scaled to the smaller pool: the ~36 GB fp8 KV pool holds ~52K tokens (vs ~125K at GMU 0.85), so 32K fits one full-context stream with headroom for a partial second.
- `num_speculative_tokens=15` — z-lab's recommended DFlash block depth for this pair; deeper blocks widen the verification batch and add a little draft KV.
- `max-num-seqs=2` — matches the ~52K-token KV pool (~1.5 full-context 32K streams); also well under Spark's bandwidth ceiling where >4 decode streams spike TTFT.
- `max-num-batched-tokens=16384` — prefill chunk halved alongside the pool to shrink the activation working set; still raises prefill throughput and gives the drafter context per step, at a smaller peak footprint.

### Container management

```bash
docker logs -f vllm-qwen36
docker stop vllm-qwen36
docker rm vllm-qwen36
```

---

## diffusiongemma-26B-A4B-it-NVFP4

**RedHatAI/diffusiongemma-26B-A4B-it-NVFP4** — a diffusion-decoding Gemma variant. Instead of autoregressive token-by-token decode, blocks are denoised bidirectionally, so it requires:

- `VLLM_USE_V2_MODEL_RUNNER=1` — diffusion decoding is only implemented in the V2 model runner (set directly by the launcher)
- `--attention-backend TRITON_ATTN` — the backend that supports the bidirectional diffusion decode path
- `--trust-remote-code` — custom modelling code

The launcher (`serve-diffusiongemma-26b-a4b.sh`) sets these plus:

- `--max-num-seqs 4` — Spark bandwidth ceiling; >4 concurrent decode streams spikes TTFT
- `--hf-overrides '{"diffusion_sampler": "entropy_bound", "diffusion_entropy_bound": 0.1}'` — entropy-bound sampler: stops denoising a block early once per-token entropy drops below 0.1, instead of running a fixed step count
- `--default-chat-template-kwargs '{"enable_thinking": true}'` — thinking mode on by default; clients can override per-request

### Agentic serving (on by default, UNVERIFIED parsers)

DiffusionGemma supports structured tool use and a reasoning channel, but no official doc names vLLM parsers for it. Since it shares Gemma 4's architecture and reasoning-channel format, the launcher defaults to the Gemma 4 recipe's parsers:

- `--enable-auto-tool-choice --tool-call-parser gemma4`
- `--reasoning-parser gemma4`

The model's bundled chat template is used as-is (no `--chat-template` override), so `--default-chat-template-kwargs '{"enable_thinking": true}'` applies and clients can override `enable_thinking` per-request.

**Verify on first run:** send a request with a tool schema and confirm the response contains parsed `tool_calls` (not inline text), and that thinking lands in `reasoning_content`. Knobs: `AGENTIC=0` disables agentic serving; `TOOL_PARSER` / `REASONING_PARSER` override the parsers; set `CHAT_TEMPLATE=examples/tool_chat_template_gemma4.jinja` only if the bundled template's tool formatting turns out broken (note that template may not accept the `enable_thinking` kwarg).

### Quick start

```bash
export HF_TOKEN=hf_xxx
bash serve-diffusiongemma-26b-a4b.sh
```

```
Ready.    http://localhost:8000/v1
Metrics:  http://localhost:8000/metrics
Logs:     docker logs -f vllm-dgemma
```

Standard launcher env vars apply (`BIND_ADDR`, `API_KEY`, `PORT`, `SKIP_PRESTAGE`, ...). Container name defaults to `vllm-dgemma`.

### Container management

```bash
docker logs -f vllm-dgemma
docker stop vllm-dgemma
docker rm vllm-dgemma
```

---

## Gemma-4-26B-A4B-NVFP4

Serve **nvidia/Gemma-4-26B-A4B-NVFP4** via vLLM in a Docker container with automatic weight pre-staging from HuggingFace.

The launcher script (`run-gemma4-26b-a4b-spark.sh`) handles:

1. **Pre-staging weights** into a host-mounted HF cache (download once, reuse across restarts)
2. **Launching vLLM** in a Docker container, tuned for Spark's unified-memory profile
3. **Waiting for readiness**, streaming container logs while the safetensor load completes
4. **Pre-warming the JIT** so the first real request doesn't eat cold-start compilation

## Requirements

- NVIDIA DGX Spark (GB10 / `sm_121`) with the NVIDIA container runtime
- Docker with `--gpus all` support
- `HF_TOKEN` set for gated model access
- `jq` and `curl` (for the readiness check and JIT warm-up)

## Quick start

```bash
export HF_TOKEN=hf_xxx
bash run-gemma4-26b-a4b-spark.sh
```

The server binds on `0.0.0.0:8000` by default and is reachable from other machines on the network. An API key is auto-generated each run and printed at the end.

```
Ready. Local endpoint: http://localhost:8000/v1
Metrics:               http://localhost:8000/metrics
Logs:                  docker logs -f vllm-gemma4
```

## Configuration

All knobs are environment variables — pass them inline or `export` before running.

| Variable | Default | Description |
|---|---|---|
| `MODEL` | `nvidia/Gemma-4-26B-A4B-NVFP4` | HuggingFace model ID |
| `SERVED_NAME` | same as `MODEL` | Model ID reported to API clients |
| `IMAGE` | `ghcr.io/spark-arena/dgx-vllm-eugr-nightly` | vLLM Docker image |
| `PORT` | `8000` | Host port to publish |
| `BIND_ADDR` | `0.0.0.0` | Host interface; set to `127.0.0.1` to restrict to local only |
| `API_KEY` | auto-generated | Bearer token for request auth; pin this for stable key across restarts |
| `GPU_MEM_UTIL` | `0.85` | Fraction of the 128 GB unified pool claimed by vLLM |
| `MAX_MODEL_LEN` | `131072` | Max context length (128 K) |
| `MAX_NUM_SEQS` | `4` | Max concurrent sequences; capped at 4 for Spark's bandwidth budget |
| `MAX_NUM_BATCHED_TOKENS` | `16384` | Prefill chunk size per scheduler step |
| `KV_CACHE_DTYPE` | `auto` | KV precision; `auto` = full precision (recommended — this model's checkpoint ships no fp8 KV scaling factors) |
| `LOAD_STRATEGY` | _(empty)_ | Safetensors load strategy: empty = lazy mmap (best for local NVMe), `prefetch`, or `eager` |
| `AGENTIC` | `1` | Set to `0` to disable tool-call/reasoning parsers |
| `TOOL_PARSER` | `gemma4` | vLLM tool-call parser name |
| `REASONING_PARSER` | `gemma4` | vLLM reasoning parser name |
| `CHAT_TEMPLATE` | `examples/tool_chat_template_gemma4.jinja` | Chat template for tool calling |
| `HF_CACHE` | `~/.cache/huggingface` | Host path for the HF weight cache |
| `VLLM_CACHE` | `~/.cache/vllm` | Host path for the vLLM torch.compile cache (persisted across restarts) |
| `SKIP_PRESTAGE` | `0` | Set to `1` to skip the weight pre-staging step |
| `CONTAINER_NAME` | `vllm-gemma4` | Docker container name |

Examples:

```bash
# Restrict to local access only, use a stable API key
BIND_ADDR=127.0.0.1 API_KEY=sk-mykey bash run-gemma4-26b-a4b-spark.sh

# Skip pre-staging if weights are already cached, disable agentic parsing
SKIP_PRESTAGE=1 AGENTIC=0 bash run-gemma4-26b-a4b-spark.sh

# Use the model-specific image tag instead of the rolling nightly
IMAGE=vllm/vllm-openai:gemma4-unified-cu130 bash run-gemma4-26b-a4b-spark.sh
```

## Agentic serving

Tool calling and reasoning are **on by default**, configured per the [vLLM Gemma 4 recipe](https://docs.vllm.ai/projects/recipes/en/latest/Google/Gemma4.html):

- `--enable-auto-tool-choice --tool-call-parser gemma4` — Gemma 4 uses a custom (non-JSON) tool-call format; the parser and chat template must match
- `--reasoning-parser gemma4`
- `--chat-template examples/tool_chat_template_gemma4.jinja`
- Prefix caching and chunked prefill are enabled — shared system prompts and tool schemas are cached across turns, cutting TTFT sharply for multi-turn agent sessions

## Performance notes (measured on DGX Spark, 2026-06-04)

- Weights: 17.50 GiB checkpoint, ~112 s to load from local NVMe
- KV cache pool: 78.82 GiB / 688,704 tokens (at `gpu-memory-utilization=0.85`, fp8)
- At 128 K context, full-precision KV fits ~2–3 full-context sequences; fp8 fits ~5 — hence `max-num-seqs=4`
- `torch.compile` (Dynamo + Inductor) took ~35 s on first boot; persisted to `VLLM_CACHE` so subsequent restarts skip it
- Default generation config (`temperature=1.0`, `top_k=64`, `top_p=0.95`) is set by the model's `generation_config.json`; pass a lower temperature per-request for reliable tool calling

## Benchmarking

`benchmark-gemma4.sh` runs a [GuideLLM](https://github.com/neuralmagic/guidellm) suite against the live server. Four runs bracket the system from best-case latency to saturation:

| # | Name | Profile | Shape | Purpose |
|---|---|---|---|---|
| 1 | **floor** | synchronous | ~8K in / ~1K out | Best-case TTFT/ITL with zero contention |
| 2 | **operating** | concurrent 1,2,4 | ~8K in / ~1K out + 2K shared prefix | Realistic agentic load, prefix-cache warm |
| 3 | **ceiling** | throughput 1,2,4,8 req/s | ~8K in / ~1K out, no prefix | Rate sweep to find throughput ceiling and saturation knee, cache-cold |
| 4 | **large** | concurrent 1,2,4 | ~32K in / ~512 out, no prefix | Prefill TTFT + KV capacity at high context |

```bash
pip install guidellm

export API_KEY=sk-...          # key printed by run-gemma4-26b-a4b-spark.sh
./benchmark-gemma4.sh          # all four runs
./benchmark-gemma4.sh 2        # just the operating/SLO run
./benchmark-gemma4.sh floor large  # subset, in order
```

Results are written as JSON to `./guidellm-results/`. Override the output directory with `OUT_DIR=...`.

| Variable | Default | Description |
|---|---|---|
| `API_KEY` | _(required)_ | Bearer token from the server |
| `TARGET` | `http://localhost:8000` | vLLM server base URL |
| `MODEL` | `nvidia/Gemma-4-26B-A4B-NVFP4` | Model ID sent to GuideLLM |
| `PROCESSOR` | same as `MODEL` | Tokenizer for synthetic data generation |
| `OUT_DIR` | `./guidellm-results` | Directory for JSON result files |

## Container management

```bash
# View live logs
docker logs -f vllm-gemma4

# Stop (won't auto-restart)
docker stop vllm-gemma4

# Remove
docker rm vllm-gemma4
```

The container is started with `--restart unless-stopped`, so it survives host reboots but stays down after an explicit `docker stop`.

## References

- [vLLM DGX Spark recipe](https://vllm.ai/blog/2026-06-01-vllm-dgx-spark)
- [vLLM Gemma 4 usage guide](https://docs.vllm.ai/projects/recipes/en/latest/Google/Gemma4.html)
- [vLLM Qwen3.8-27B recipe](https://recipes.vllm.ai/Qwen/Qwen3.8-27B)
- [SGLang cookbook — Qwen3.8-27B](https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B)
- [MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark) — source of the SGLang flag stack and the measured numbers quoted above
- [Qwen3.8-27B NVFP4 on a single DGX Spark — vLLM + MTP measurements (NVIDIA developer forum)](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-a-single-dgx-spark-up-to-1m-context-vllm-mtp-measurements/380244)
