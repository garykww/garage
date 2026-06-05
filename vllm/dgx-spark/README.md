# dgx-spark

Serve **nvidia/Gemma-4-26B-A4B-NVFP4** via vLLM on an NVIDIA DGX Spark (GB10, `sm_121`), with an OpenAI-compatible endpoint ready for agentic / tool-calling workloads.

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
| `IMAGE` | `vllm/vllm-openai:cu130-nightly` | vLLM Docker image |
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
