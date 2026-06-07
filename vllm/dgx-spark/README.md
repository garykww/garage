# dgx-spark

vLLM launch scripts for NVIDIA DGX Spark (GB10, `sm_121`), with OpenAI-compatible endpoints ready for agentic / tool-calling workloads.

| Script | Model | Notes |
|---|---|---|
| `run-gemma4-26b-a4b-spark.sh` | `nvidia/Gemma-4-26B-A4B-NVFP4` | Docker-based, HF-hosted weights, agentic tool calling |
| `serve-qwen36-35b-a3b-dflash.sh` | `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | Docker-based, DFlash speculative decoding |
| `serve-nemotron3-super-120b-a12b-nvfp4.sh` | `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | Docker-based, hybrid Mamba+MoE, MTP speculative decoding, 1M context |

---

## serve.sh

A generic Docker wrapper around `vllm serve`, shared by all model scripts. Adapted from `run-gemma4-26b-a4b-spark.sh` — same lifecycle: pre-stage weights, `docker run -d`, stream load logs while waiting for readiness, pre-warm the JIT. All vLLM flags are forwarded verbatim; no model-specific logic lives here.

```
bash serve.sh <model> [vllm serve flags...]
```

The image's ENTRYPOINT is the NVIDIA wrapper; `vllm serve` is passed explicitly as the command.

Script-level env vars (not forwarded to vLLM):

| Variable | Default | Description |
|---|---|---|
| `IMAGE` | `ghcr.io/spark-arena/dgx-vllm-eugr-nightly` | vLLM Docker image |
| `CONTAINER_NAME` | `vllm-serve` | Docker container name |
| `PORT` | `8000` | Host port; maps to container-internal port 8000 |
| `BIND_ADDR` | `0.0.0.0` | Host bind address; set to `127.0.0.1` to restrict to local only |
| `API_KEY` | auto-generated | Bearer token; auto-generated if unset so endpoint is never unauthenticated |
| `HF_TOKEN` | _(empty)_ | HuggingFace token for gated models |
| `HF_CACHE` | `~/.cache/huggingface` | Host HF weight cache |
| `VLLM_CACHE` | `~/.cache/vllm` | Host torch.compile cache; persisted across restarts so the ~35s compile is paid once |
| `SHM_SIZE` | _(empty)_ | If set (e.g. `16g`), uses `--shm-size` instead of `--ipc=host` for `/dev/shm` |
| `SKIP_PRESTAGE` | `0` | Set to `1` to skip weight pre-staging |
| `VLLM_DOCKER_ENV` | _(empty)_ | Extra container env vars (space/newline-separated `KEY=VALUE`) → `-e KEY=VALUE`; for engine tuning a recipe needs at runtime |
| `EXTRA_MOUNTS` | _(empty)_ | Extra bind mounts (space/newline-separated `SRC:DST`) → `-v SRC:DST`; for mounting files (e.g. a parser plugin) into the serving container |

---

## Qwen3.6-35B-A3B-NVFP4 (DFlash)

**RedHatAI/Qwen3.6-35B-A3B-NVFP4** with DFlash speculative decoding via **z-lab/Qwen3.6-35B-A3B-DFlash**.

The launcher (`serve-qwen36-35b-a3b-dflash.sh`):

1. **Pre-stages** the DFlash draft model into the host HF cache (`serve.sh` handles the main model)
2. **Delegates to `serve.sh`** with all recommended flags pre-set

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

Memory budget on the 128 GB **unified** pool (shared by the GPU's `gpu-memory-utilization` fraction, the container's `/dev/shm`, and the host OS): NVFP4 target weights ~20 GB, the **0.5B DFlash drafter ~1 GB**, the rest of the fraction is KV cache.

- `gpu-memory-utilization=0.85` — vLLM loads the target weights, the DFlash drafter, **and** the KV cache all *inside* this fraction; the drafter and its KV contend with the target KV cache here, they are not allocated outside it. 0.85 (~109 GB) maximizes the KV pool to reach 64K context; the ~19 GB left suffices for the host because single-GPU `/dev/shm` use is small and the 16g shm cap is lazy.
- `kv-cache-dtype=fp8` + `calculate-kv-scales` — fp8 ~halves KV bytes/token, ~doubling the pool so 64K fits on the 128 GB box. Full-precision `auto` only yielded a ~58.6K-token pool (a single request ran out of KV before 128K). The checkpoint ships no KV scales, so `--calculate-kv-scales` computes them on the fly during prefill instead of falling back to `scale=1.0` (which risks fp8 overflow / accuracy loss). Small accuracy cost in exchange for the larger context.
- `max-model-len=65536` — 64K, reachable because fp8 KV + GMU 0.85 give a ~125K-token pool; 64K fits with room for a second concurrent stream.
- `num_speculative_tokens=15` — z-lab's recommended DFlash block depth for this pair; deeper blocks widen the verification batch and add a little draft KV. Live acceptance ~3.4 accepted tokens/step (≈4.4 tokens per target forward).
- `max-num-seqs=4` — Spark bandwidth ceiling; >4 concurrent decode streams spikes TTFT
- `max-num-batched-tokens=32768` — z-lab's recommended prefill chunk; raises prefill throughput and gives the drafter more context, at the cost of an ~8× larger activation working set and potentially higher TTFT under concurrency

### Container management

```bash
docker logs -f vllm-qwen36
docker stop vllm-qwen36
docker rm vllm-qwen36
```

---

## Nemotron-3-Super-120B-A12B-NVFP4

**nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4** — a ~120B-total / ~12B-active hybrid **Mamba-2 + latent-MoE** model with **MTP (Multi-Token Prediction) speculative decoding** baked into the checkpoint. Flags follow NVIDIA's [official Nemotron 3 Super DGX Spark guide](https://docs.nvidia.com/nemotron/nightly/usage-cookbook/Nemotron-3-Super/SparkDeploymentGuide/README.html).

The launcher (`serve-nemotron3-super-120b-a12b-nvfp4.sh`):

1. **Downloads the `super_v3` reasoning-parser plugin** from the model repo (it ships there, not in the image) and caches it on the host
2. **Delegates to `serve.sh`**, passing the parser plugin via `EXTRA_MOUNTS` and the NVFP4 engine env vars via `VLLM_DOCKER_ENV`

### Image

Default `ghcr.io/spark-arena/dgx-vllm-eugr-nightly` — the patched DGX Spark image. **Stock vLLM containers fail with "illegal instruction" on NVFP4/GB10**, so the patched image (or `VLLM_NVFP4_GEMM_BACKEND=marlin`, which this script sets) is required.

### Requirements

- NVIDIA DGX Spark (GB10 / `sm_121`) with the NVIDIA container runtime
- Docker with `--gpus all` support
- `HF_TOKEN` set — the model **and** its parser-plugin `/raw/` download are gated
- `curl` (parser download, readiness check, warm-up)

### Quick start

```bash
export HF_TOKEN=hf_xxx
bash serve-nemotron3-super-120b-a12b-nvfp4.sh
```

```
Ready.    http://localhost:8000/v1
Metrics:  http://localhost:8000/metrics
Logs:     docker logs -f vllm-nemotron3-super
```

Examples:

```bash
# Drop to a shorter context for more decode concurrency headroom
MAX_MODEL_LEN=262144 bash serve-nemotron3-super-120b-a12b-nvfp4.sh

# Disable MTP speculative decoding (e.g. if startup OOMs on the spec-decode state)
NO_MTP=1 bash serve-nemotron3-super-120b-a12b-nvfp4.sh
```

### Performance / config notes (DGX Spark, GB10)

The 128 GB **unified** pool is shared by the `gpu-memory-utilization` fraction, `/dev/shm`, and the host OS.

- `gpu-memory-utilization=0.90` — per the official guide; NVFP4 weights + Mamba SSM state + KV cache all live inside this fraction
- `max-model-len=1000000` — 1M context is affordable here because the model is **mostly Mamba-2**: those layers carry a constant-size SSM state instead of length-growing KV, so only the few attention layers populate the KV cache. `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` (set by the script) permits it; lower `MAX_MODEL_LEN` for more concurrency headroom
- `kv-cache-dtype=fp8` — required to fit the long context in the unified pool (unlike the Gemma/Qwen recipes, which use full-precision KV)
- `mamba_ssm_cache_dtype=float32` — the SSM state stays fp32 for stability, separate from the fp8 attention KV
- `quantization=fp4` + `moe-backend=marlin` — marlin is the FP4 MoE backend that runs on GB10
- MTP speculative decoding (`speculative_config method=mtp`, 3 tokens) is **on by default**; the draft layer is in the checkpoint so the extra KV/latency is one layer per predicted token. Some users hit MTP+NVFP4 OOM on other GPUs — use `NO_MTP=1` if startup fails allocating the spec-decode state
- `max-num-seqs=4` — Spark bandwidth ceiling; >4 concurrent decode streams spikes TTFT
- Agentic: `--tool-call-parser qwen3_coder` + the mounted `super_v3` reasoning parser plugin

### Container management

```bash
docker logs -f vllm-nemotron3-super
docker stop vllm-nemotron3-super
docker rm vllm-nemotron3-super
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
