# Workflow template sources

`ui/` holds ComfyUI's UI *graph* format — copied by `run-comfyui-h3-spark.sh` into
`~/Workspace/comfyui/workflows` (ComfyUI's per-user workflow directory, mounted writable), skipping
any file already there, so they appear in the Workflows tab.
`api-examples/` holds flat *API* prompts for CLI use (not loadable in the UI) — see below.

Originally vendored (not fetched at runtime) 2026-08-15 from the official ComfyUI workflow
templates repo, so this folder stays self-contained and a known-working version is pinned:

- `ui/video_minimax_h3_t2v.json` — https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_t2v.json
- `ui/video_minimax_h3_i2v.json` — https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_i2v.json
- `ui/video_minimax_h3_r2v.json` — https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_r2v.json

**Locally edited, 2026-08-15**: as fetched, all three have their `UNETLoader`/`CLIPLoader` node
widget values hardcoded to the `pruned` QUANT tier's filenames (`minimax_h3_fl2va_pruned_int8_convrot`
+ `qwen3vl_32b_minimax_h3_nvfp4_awq`, or `minimax_h3_ref2va_pruned_int8_convrot` for R2V) — confirmed
this throws "Missing Models" in the UI against the then-default `int8` tier. The loader nodes were
retargeted to the `int8` filenames:

| File | `UNETLoader` node | now points to |
|---|---|---|
| `ui/video_minimax_h3_t2v.json` | id `6` (inside the `Image to Video (MiniMax H3)` subgraph) | `minimax_h3_fl2va_int8_convrot.safetensors` |
| `ui/video_minimax_h3_i2v.json` | id `6` (same subgraph) | `minimax_h3_fl2va_int8_convrot.safetensors` |
| `ui/video_minimax_h3_r2v.json` | id `127` (top-level, no subgraph) | `minimax_h3_ref2va_pruned_int8_convrot.safetensors` |

All three `CLIPLoader` nodes (ids `13`, `13`, `128` respectively) now point to
`qwen3vl_32b_minimax_h3_int8_convrot.safetensors`.

**Re-edited 2026-09-13**: the script now mounts the fixed weight set from `spark-control-plane`'s
recipe, which includes ref2va only as `minimax_h3_ref2va_pruned_int8_convrot`, not the int8 one. R2V's
`UNETLoader` was pointed back to the pruned file so it resolves. Every filename in all three files is
now in that mounted set.

If MiniMax H3 support in ComfyUI moves forward materially, re-fetch these from the same
`Comfy-Org/workflow_templates` repo, re-check every loader filename against the script's
`MODEL_FILES`, and update this file's date.

## `smoke_test_api_prompt.json`

Not vendored from upstream — hand-built and validated end-to-end on `nv-spark-01` on 2026-08-15
(see README.md "CLI smoke test"). The three files above are ComfyUI's UI *graph* format; loading
them requires the browser (`video_minimax_h3_t2v.json`'s pipeline is nested inside a subgraph,
which ComfyUI's `/prompt` API cannot execute directly). This file is the flat *API* prompt format
(`{"prompt": {node_id: {class_type, inputs}}}`) that `/prompt` expects, built directly from each
node's `/object_info` schema and using each field's own declared default except where deliberately
shrunk for speed (512x288 resolution, 5-frame length — the minimum on the model's 17k+5 frame
grid, 8 sampling steps). It mirrors the same node topology as the vendored T2V subgraph
(UNETLoader → CLIPLoader → VAELoader×2 → MiniMaxH3ImageToVideo → MiniMaxH3SigmaShift →
BasicGuider/RandomNoise/KSamplerSelect/BasicScheduler → SamplerCustomAdvanced → VAEDecode +
VAEDecodeAudio → CreateVideo → SaveVideo), just without the `ComfyMathExpression`/`PrimitiveFloat`
nodes that dynamically compute the sigma-shift values in the original — this uses
`MiniMaxH3SigmaShift`'s own schema defaults (`shift_video=12.0`, `shift_audio=3.0`) instead.

## `minimax_h3_t2v.json`, `minimax_h3_t2v_8step.json`, `minimax_h3_t2v_quality.json`, `minimax_h3_ref2v.json`

Copied 2026-09-10 from `discord-comfyui-bot`'s `workflows/` (a separate project, same author) - the
`draft`/`fast`/`quality`/`ref2v` presets its `/video` command actually renders with, validated
end-to-end through the real bot against this same recipe's weights. Same flat API *prompt* format as
`smoke_test_api_prompt.json` above, but **NOT wrapped in `{"prompt": ...}`** - the bot's own client
does that when it POSTs to `/prompt`, so wrap these yourself before curling them directly (or point
`discord-comfyui-bot` at this ComfyUI instance and let it do that).

Checked against what this recipe now stages (`recipes.yaml`'s `comfyui-minimax-h3` /
`-sage`) rather than the `int8`-retargeted `ui/` templates above: every `UNETLoader`/`CLIPLoader`/
`LoraLoaderModelOnly` filename in all four resolves as-is -
`minimax_h3_fl2va_pruned_int8_convrot.safetensors` / `minimax_h3_ref2va_pruned_int8_convrot.safetensors`,
`qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`, and the matching turbo LoRA - no filename edits
needed here, unlike the `ui/` files. If `discord-comfyui-bot`'s `config.json` presets change which
files they reference, re-copy from there and update this note's date.
