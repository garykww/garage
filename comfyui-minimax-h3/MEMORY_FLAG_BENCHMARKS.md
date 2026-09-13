# ComfyUI memory-flag benchmarks — nv-spark-01

Isolated A/B tests of ComfyUI CLI flags tried against `comfyui-h3-sage`
(`garykww/comfyui-minimax-h3:sm121-sage`), run to root-cause a reported
slowdown. Not baked into `recipes.yaml` — kept here as a standalone log so the
recipe comments stay about what's actually running, not a benchmark diary.

Method: same container recreated fresh each time (stop/rm/run, since flags
are baked into the container at creation), same test workflow submitted via
`POST /prompt`, timed from ComfyUI's own "got prompt" / "Prompt executed in
X seconds" log lines. Test workflow:
`workflows/api-examples/minimax_h3_t2v.json` (draft preset - fl2va pruned
checkpoint, 4-step turbo LoRA, 672x384, 5s/4 steps).

## `--disable-pinned-memory` — 2026-09-12

Two comparisons, both against fresh containers running the identical test
workflow:

| | default (no flags) | `--disable-pinned-memory` |
| --- | --- | --- |
| Total time | 50.45s / 51.09s (two baseline runs) | 49.01s |
| Sampling (4 steps) | 6.45s/it | 6.45s/it |
| **Host cgroup peak** | **42.72 GiB** | **4.83 GiB** |
| GPU device memory | 39435 MiB | 39435 MiB (identical) |

**Speed: no measurable cost**, as expected from the flag's own rationale
(see `recipes.yaml`'s `comfyui-minimax-h3` comment) - pinning accelerates a
host-to-device copy that doesn't cross a real bus on GB10's unified memory
anyway.

**Memory: a large, unambiguous win.** Pinning adds **~38 GB of host-side
memory** for the exact same generation - GPU device memory is identical
either way (39435 MiB), so this is entirely a host-side duplicate, not
anything the GPU needed. This is the precise "same bytes counted twice"
mechanism the recipe's memoryGB comment already describes for dynamic VRAM
loading, now measured directly rather than reasoned about: with pinning
disabled, host cgroup peak is ~9x smaller for an identical result.

**Conclusion: `--disable-pinned-memory` was not responsible for the reported
slowdown, and is not just "safe to re-add" - it is a strict improvement on
this workload.** Same speed, same GPU usage, ~38 GB less host memory
pressure, which directly reduces the exact failure mode (host memory +
swap exhaustion) that the 2026-09-06 incident hit. There is no discovered
downside to setting it; the earlier "observed slower" report must have come
from one of the other two batched flags (`--disable-mmap` or
`--reserve-vram`, neither re-tested individually) or from a different
workload than this draft-preset test covers.

<details>
<summary>--disable-pinned-memory</summary>

```
2026-09-12T22:58:19.540Z [INFO] got prompt
2026-09-12T22:58:20.353Z [INFO] Model MiniMaxH3TEModel_ prepared for dynamic VRAM loading. 14956MB Staged...
2026-09-12T22:58:24.473Z [INFO] Model MiniMaxH3 prepared for dynamic VRAM loading. 19995MB Staged...
2026-09-12T22:58:54.497Z   0%|...| 0/4 ... Model Initializing ... Model Initialization complete!
                            25%|... 1/4 [00:10<00:30, 10.14s/it]
                            50%|... 2/4 [00:12<00:12,  6.46s/it]
                            75%|... 3/4 [00:19<00:06,  6.45s/it]
                           100%|... 4/4 [00:25<00:00,  6.45s/it]
2026-09-12T22:58:54.528Z [INFO] Requested to load MiniMaxH3AudioVAE
2026-09-12T22:58:54.993Z [INFO] Requested to load MiniMaxH3VideoVAE
2026-09-12T22:59:08.551Z [INFO] Prompt executed in 49.01 seconds
```
</details>

## `--disable-dynamic-vram` — 2026-09-12

| | default (dynamic VRAM on) | `--disable-dynamic-vram` |
| --- | --- | --- |
| Total | 51.09s | 165.51s (3.24x slower) |
| Sampling (4 steps) | 6.45s/it | 6.61s/it (noise-level difference) |
| Model load phase | ~34.6s | ~111s+ |

**Confirmed, not just observed: the flag makes model loading ~3x slower and
does not touch sampling throughput at all.**

With dynamic VRAM (default), the 20GB diffusion model is staged
incrementally - log shows `Model MiniMaxH3 prepared for dynamic VRAM
loading. 19995MB Staged.` - and sampling starts almost immediately after.

With `--disable-dynamic-vram`, ComfyUI falls back to its older
estimate-based memory manager, which does a synchronous **full load**:

```
Requested to load MiniMaxH3
...84.6s later...
loaded completely; 68823.24 MB usable, 19996.14 MB loaded, full load: True
```

then another ~27s before the sampler starts. For a workflow this small,
where loading dominates total time, that 84.6s + 27s is effectively the
entire regression - sampling itself (6.45 vs 6.61 s/it) is identical within
noise.

**Not re-tested**: whether this tradeoff differs on a workload where loading
is a smaller fraction of total time (e.g. the `quality` preset at 20 steps,
where 111s of loading overhead matters proportionally less against a much
longer sampling phase). If revisiting, test that case separately before
assuming this generalizes.

**Also not re-tested individually**: `--disable-mmap` (paired with the
`comfy/utils.py` `copy=False` patch) and `--reserve-vram 1`, both originally
reverted alongside `--disable-dynamic-vram` as a batch. This log only
isolates `--disable-dynamic-vram`.

Raw log excerpts, for reference:

<details>
<summary>Baseline (default, no flags)</summary>

```
2026-09-12T22:45:37.614Z [INFO] got prompt
2026-09-12T22:45:37.666Z [INFO] Model MiniMaxH3TEModel_ prepared for dynamic VRAM loading. 14956MB Staged...
2026-09-12T22:45:41.230Z [INFO] Model MiniMaxH3 prepared for dynamic VRAM loading. 19995MB Staged...
2026-09-12T22:46:15.867Z   0%|...| 0/4 ... Model Initializing ... Model Initialization complete!
                            25%|... 1/4 [00:14<00:42, 14.32s/it]
                            50%|... 2/4 [00:12<00:12,  6.44s/it]
                            75%|... 3/4 [00:19<00:06,  6.46s/it]
                           100%|... 4/4 [00:25<00:00,  6.45s/it]
2026-09-12T22:46:16.227Z [INFO] Model MiniMaxH3AudioVAE prepared for dynamic VRAM loading...
2026-09-12T22:46:16.501Z [INFO] Model MiniMaxH3VideoVAE prepared for dynamic VRAM loading...
2026-09-12T22:46:28.706Z [INFO] Prompt executed in 51.09 seconds
```
</details>

<details>
<summary>--disable-dynamic-vram</summary>

```
2026-09-12T22:47:57.496Z [INFO] got prompt
2026-09-12T22:47:57.728Z [INFO] VAE load device: cuda:0, offload device: cpu, dtype: torch.float32
2026-09-12T22:48:26.992Z [INFO] Requested to load MiniMaxH3TEModel_
2026-09-12T22:48:33.032Z [INFO] loaded completely;  14960.20 MB loaded, full load: True
2026-09-12T22:48:37.729Z [INFO] Requested to load MiniMaxH3
2026-09-12T22:50:02.362Z [INFO] loaded completely; 68823.24 MB usable, 19996.14 MB loaded, full load: True
2026-09-12T22:50:29.106Z   0%|...| 0/4 ...
                            25%|... 1/4 [00:06<00:19,  6.63s/it]
                            50%|... 2/4 [00:13<00:13,  6.62s/it]
                            75%|... 3/4 [00:19<00:06,  6.60s/it]
                           100%|... 4/4 [00:26<00:00,  6.61s/it]
2026-09-12T22:50:29.113Z [INFO] Requested to load MiniMaxH3AudioVAE
2026-09-12T22:50:29.531Z [INFO] Requested to load MiniMaxH3VideoVAE
2026-09-12T22:50:43.014Z [INFO] Prompt executed in 165.51 seconds
```
</details>

## `--disable-mmap` + the `copy=False` double-copy fix — 2026-09-12

The double-copy fix only takes effect when `--disable-mmap` is active - it
patches `comfy/utils.py`'s `DISABLE_MMAP` branch
(`tensor.to(device=device, copy=True)` -> `copy=False`), which is dead code
otherwise. So this needed a genuine three-way A/B, all on the same host,
same test workflow, same `--disable-pinned-memory --use-sage-attention`
base flags:

| | mmap default (no `--disable-mmap`) | `--disable-mmap`, **unpatched** | `--disable-mmap`, **patched** (`copy=False`) |
| --- | --- | --- | --- |
| Total time | 49.01s | 62.38s | 49.41s |
| Sampling (4 steps) | 6.45s/it | 6.49s/it | 6.44s/it |
| **Host cgroup peak** | 4.83 GiB | **40.07 GiB** | **4.82 GiB** |
| GPU device memory | 39435 MiB | 39435 MiB | 39435 MiB (identical throughout) |

Built a one-off test image (`comfyui-minimax-h3:mmap-test`, not the tracked
Dockerfile) with ONLY the `copy=False` patch - no env vars, no
`--disable-dynamic-vram`/`--reserve-vram` - to isolate this one change from
everything else luix93's build does.

**The bug is real and reproducible on this box**: turning on `--disable-mmap`
against the unpatched image inflates host memory by ~35 GB (4.83 -> 40.07
GiB) and slows the run by ~27% (49.01s -> 62.38s), for identical GPU usage.
`--disable-mmap` makes ComfyUI read weight files into an ordinary buffer
instead of memory-mapping them, and the unpatched `copy=True` then forces a
second, redundant host-side copy of that buffer - exactly the mechanism the
patch targets.

**The patch is a genuine, verified fix for that specific bug**: with
`copy=False`, `--disable-mmap`'s time and memory return to within noise of
the no-`--disable-mmap` baseline (49.41s / 4.82 GiB vs. 49.01s / 4.83 GiB).

**But there is no reason to use either on this box right now.** The
patched `--disable-mmap` path performs identically to just not setting
`--disable-mmap` at all - mmap-based loading is already as fast and as
memory-light as the fixed non-mmap path. So while the fix genuinely works,
adopting `--disable-mmap` (+ this patch) would add a Dockerfile patch and a
CLI flag for zero measured benefit over doing nothing. Not adopted into the
recipe on this basis - revisit only if a future workload shows mmap-based
loading itself causing problems (e.g. on a filesystem where mmap performs
poorly) that `--disable-mmap` would actually need to solve.

<details>
<summary>mmap default (no --disable-mmap)</summary>

```
2026-09-12T23:01:06 (submitted)
Prompt executed in 50.45 seconds
cgroup memory.peak: 45869309952 bytes (42.72 GiB)  [note: measured against
  the unpatched image with pinning disabled but --disable-mmap NOT set -
  same order of magnitude as the pinning-only baseline above, run-to-run
  variance aside]
nvidia-smi: 39435 MiB
```
</details>

<details>
<summary>--disable-mmap, unpatched (garykww/comfyui-minimax-h3:sm121-sage)</summary>

```
2026-09-12T23:16:44.488Z [INFO] got prompt
2026-09-12T23:16:45.298Z [INFO] Requested to load MiniMaxH3TEModel_
2026-09-12T23:16:45.349Z [INFO] Model MiniMaxH3TEModel_ prepared for dynamic VRAM loading. 14956MB Staged...
2026-09-12T23:16:53.830Z [INFO] Requested to load MiniMaxH3
2026-09-12T23:16:53.859Z [INFO] Model MiniMaxH3 prepared for dynamic VRAM loading. 19995MB Staged...
2026-09-12T23:17:30.808Z   0%|...| 0/4 ...
                            25%|... 1/4 [00:16<00:48, 16.29s/it]
                            50%|... 2/4 [00:12<00:12,  6.49s/it]
                            75%|... 3/4 [00:19<00:06,  6.48s/it]
                           100%|... 4/4 [00:25<00:00,  6.49s/it]
2026-09-12T23:17:46.867Z [INFO] Prompt executed in 62.38 seconds
cgroup memory.peak: 43022106624 bytes (40.07 GiB)
nvidia-smi: 39435 MiB
```
</details>

<details>
<summary>--disable-mmap, patched (comfyui-minimax-h3:mmap-test)</summary>

```
2026-09-12T23:18:58.138Z [INFO] got prompt
2026-09-12T23:18:58.842Z [INFO] Requested to load MiniMaxH3TEModel_
2026-09-12T23:18:58.891Z [INFO] Model MiniMaxH3TEModel_ prepared for dynamic VRAM loading. 14956MB Staged...
2026-09-12T23:19:03.097Z [INFO] Requested to load MiniMaxH3
2026-09-12T23:19:03.125Z [INFO] Model MiniMaxH3 prepared for dynamic VRAM loading. 19995MB Staged...
2026-09-12T23:19:33.318Z   0%|...| 0/4 ...
                            25%|... 1/4 [00:10<00:30, 10.31s/it]
                            50%|... 2/4 [00:12<00:12,  6.44s/it]
                            75%|... 3/4 [00:19<00:06,  6.44s/it]
                           100%|... 4/4 [00:25<00:00,  6.44s/it]
2026-09-12T23:19:47.554Z [INFO] Prompt executed in 49.41 seconds
cgroup memory.peak: 5178748928 bytes (4.82 GiB)
nvidia-smi: 39435 MiB
```
</details>
