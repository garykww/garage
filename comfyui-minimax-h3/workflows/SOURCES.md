# Workflow template sources

`ui/` holds ComfyUI's UI *graph* format — mounted read-only into ComfyUI's per-user workflow
directory (`run-comfyui-h3-spark.sh`'s `WORKFLOWS_DIR`), so they appear in the Workflows tab.
`api-examples/` holds flat *API* prompts for CLI use (not loadable in the UI) — see below.

Originally vendored (not fetched at runtime) 2026-08-15 from the official ComfyUI workflow
templates repo, so this folder stays self-contained and a known-working version is pinned:

- `ui/video_minimax_h3_t2v.json` — https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_t2v.json
- `ui/video_minimax_h3_i2v.json` — https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_i2v.json
- `ui/video_minimax_h3_r2v.json` — https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_r2v.json

**Locally edited, 2026-08-15**: as fetched, all three have their `UNETLoader`/`CLIPLoader` node
widget values hardcoded to the `pruned` QUANT tier's filenames (`minimax_h3_fl2va_pruned_int8_convrot`
+ `qwen3vl_32b_minimax_h3_nvfp4_awq`, or `minimax_h3_ref2va_pruned_int8_convrot` for R2V) — confirmed
this throws "Missing Models" in the UI against this recipe's `int8`-tier default. Rather than stage
an extra ~54GB of `pruned`-tier weights, the two loader nodes in each file were retargeted to the
`int8` filenames instead:

| File | `UNETLoader` node | now points to |
|---|---|---|
| `ui/video_minimax_h3_t2v.json` | id `6` (inside the `Image to Video (MiniMax H3)` subgraph) | `minimax_h3_fl2va_int8_convrot.safetensors` |
| `ui/video_minimax_h3_i2v.json` | id `6` (same subgraph) | `minimax_h3_fl2va_int8_convrot.safetensors` |
| `ui/video_minimax_h3_r2v.json` | id `127` (top-level, no subgraph) | `minimax_h3_ref2va_int8_convrot.safetensors` |

All three `CLIPLoader` nodes (ids `13`, `13`, `128` respectively) now point to
`qwen3vl_32b_minimax_h3_int8_convrot.safetensors`. **R2V still needs an explicit
`CHECKPOINT_SET=fl2va+ref2va` pre-stage run** — the default `CHECKPOINT_SET=fl2va` never downloads
`minimax_h3_ref2va_int8_convrot.safetensors` at all, patched filename or not.

If you switch `QUANT` to `pruned` or `full`, either re-point these two nodes by hand (via the node
UI) or re-fetch fresh copies from the URLs above and update this file's date.

If MiniMax H3 support in ComfyUI moves forward materially, re-fetch these from the same
`Comfy-Org/workflow_templates` repo, re-apply the filename edit above (or switch `QUANT=pruned`
and skip it), and update this file's date.

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
