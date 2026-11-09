# Models

This page explains which language models Plug'n'Heal ships, how big they are, how a PC gets its model, and how to
change the catalogue. The data lives in [`src/catalog/models.json`](../src/catalog/models.json), the selection in
[`src/lib/Models.ps1`](../src/lib/Models.ps1) (`Select-PnhModel`) and the speed test in
[`src/lib/Ollama.ps1`](../src/lib/Ollama.ps1) (`Test-PnhModelFit`). The research behind the choice (German, with all
benchmark numbers) is [research/modelle.md](research/modelle.md).

## 1. The ladder

All models are Qwen models from the Ollama library, in GGUF format with a fixed quantisation tag, and all are
licensed under Apache-2.0. Sizes were measured on 9 November 2026 from the Ollama registry manifests (config plus
all layers, including the vision projector).

| Tag | Parameters | Size | Tier | `minVramGB` | `minRamGB` | `ctx` | `think` | Free PowerShell | Profiles |
|---|---|---|---|---|---|---|---|---|---|
| `qwen3.5:2b-q4_K_M` | 1.9B | 1.95 GB | 1 | 2.5 | 3 | 16384 | off | no | small, standard, full |
| `qwen3.5:4b-q4_K_M` | 4.2B | 3.32 GB | 2 | 4.5 | 6 | 16384 | off | no | small, standard, full |
| `qwen3.5:9b-q4_K_M` | 9.0B | 6.55 GB | 3 | 8.5 | 8 | 32768 | off | no | standard, full |
| `qwen3.5:9b-q8_0` | 9.0B | 10.45 GB | 3 | 13 | 12 | 32768 | off | no | full |
| `qwen3.8:27b-q4_K_M` | 27.3B | 17.74 GB | 4 | 21 | 20 | 32768 | on | yes | standard, full |
| `qwen3.6:35b-a3b-mtp-q4_K_M` | 35.5B (3B active, MoE) | 22.62 GB | 4 | 13 (+ `gpuMinRamGB` 30, partial offload) | 24 | 32768 | on | yes | full |

Sizes are decimal GB (10^9 bytes); the exact byte counts are in `models.json`. `minVramGB`, `minRamGB` and
`gpuMinRamGB` are GiB (PowerShell's `1GB` = 2^30 bytes).

| Field | Meaning |
|---|---|
| `tier` | 1–2 small (may run on the CPU), 3 mid-size GPU, 4 large GPU |
| `minVramGB` | GiB the model needs on the GPU at its `ctx` (weights incl. projector, KV cache in q8_0, buffers) |
| `minRamGB` | GiB it needs on the CPU path (weights, KV cache at 16k, buffers, about 1 GiB margin) |
| `gpuMinRamGB`, `partialOffload` | the MoE model is meant to run partly on the CPU; it then also needs this much system RAM |
| `ctx` | context length (`num_ctx`); capped at 16384 when a model runs on the CPU |
| `think` | default of Ollama's `think` flag; off for tiers 1–3 (thinking costs minutes on a CPU), on for tier 4. Not yet A/B tested. |
| `freeShell` | the model may propose its own PowerShell commands, filtered and confirmed (see [SAFETY.md](SAFETY.md)) |
| `confirmAllChanges` | optional; every changing action needs the user's "Yes", also when the action itself would not ask. Set for the 2B (tier 1), whose tool use is weak |
| `default` | part of the `standard` profile |

### Profiles

| Profile | Models | Model bytes | On the drive incl. runtime and reserve | Suggested SSD |
|---|---|---|---|---|
| `small` | 2B, 4B | 5,269,955,292 (5.3 GB) | about 8.1 GB | 16 GB |
| `standard` (default) | 2B, 4B, 9B, 27B | 29,562,652,974 (29.6 GB) | about 32.4 GB | 64 GB |
| `full` | all six | 62,633,185,479 (62.6 GB) | about 65.4 GB | 128 GB |

"On the drive" adds the unpacked Ollama runtime (2,263,717,391 bytes) and the 512 MiB reserve from
[`builder/versions.json`](../builder/versions.json). The suggested SSD size is the smallest usual size whose
formatted capacity (about 93 %) holds it; the Windows builder computes and shows it.

## 2. How a PC gets its model

### Step 1: rule (`Select-PnhModel`)

1. Take the installed models that are in the catalogue and rank them, largest first: by `minVramGB`, then `tier`,
   then size.
2. **Usable VRAM** = VRAM of the best **dedicated NVIDIA or AMD** GPU minus 1.5 GiB. Intel GPUs and integrated GPUs
   (also AMD APUs) count as "no GPU" until they have been measured. VRAM comes from the display driver's registry key
   (`HardwareInformation.qwMemorySize`), matched to the adapter, or from `nvidia-smi` for NVIDIA.
3. **GPU path:** the first ranked model with `minVramGB` ≤ usable VRAM (and, if set, `gpuMinRamGB` ≤ RAM) is chosen;
   it uses its catalogue `ctx`.
4. **CPU path:** otherwise the first ranked model with `tier` ≤ 2 and `minRamGB` ≤ RAM − 4 GiB; `ctx` is capped at
   16384. Dense models above 4B are never run on the CPU: they would be far too slow.
5. **Weak hardware:** if nothing fits, the smallest installed model whose `minRamGB` is at most the RAM is used anyway
   (the window says the computer is rather weak). If the RAM is smaller than every installed model needs, no model
   is chosen and the window says the computer does not have enough memory.
6. **Fallbacks:** the lower-ranked installed models that also fit, best first (if none fits, the smallest). Each
   fallback gets its own placement (GPU or CPU) and its own `ctx` (`Get-PnhModelContext`, capped at 16384 on the CPU);
   `Select-PnhModel` returns them as `Candidates`, in step-down order.

`-Prefer <tag>` (used by `Run-Headless.ps1 -Model`) overrides the rule for an installed tag.

Examples (from `tests/Models.Tests.ps1`, all six models installed):

| Hardware | Model | Where |
|---|---|---|
| RTX 4090 24 GB, 32 GB RAM | `qwen3.8:27b-q4_K_M` | GPU |
| AMD RX 7900 XTX 24 GB | `qwen3.8:27b-q4_K_M` | GPU |
| 16 GB card, 32 GB RAM | `qwen3.6:35b-a3b-mtp-q4_K_M` | GPU, partly CPU |
| 16 GB card, 16 GB RAM | `qwen3.5:9b-q8_0` | GPU |
| 12 GB card | `qwen3.5:9b-q4_K_M` | GPU |
| 6 or 8 GB card | `qwen3.5:4b-q4_K_M` | GPU |
| 4 GB card | `qwen3.5:2b-q4_K_M` | GPU |
| 2 GB card, 16 GB RAM | `qwen3.5:4b-q4_K_M` | CPU |
| no GPU, 64 GB RAM | `qwen3.5:4b-q4_K_M` | CPU (no dense model above tier 2 on the CPU) |
| no GPU, 8 GB RAM | `qwen3.5:2b-q4_K_M` | CPU |
| no GPU, 4 GB RAM | `qwen3.5:2b-q4_K_M` | CPU, "weak hardware" |
| Intel Arc 16 GB, 32 GB RAM | `qwen3.5:4b-q4_K_M` | CPU (Intel counts as no GPU) |

With the `standard` profile a 16 GB card gets `qwen3.5:9b-q4_K_M`, because the two `full`-only models are missing.

### Step 2: measurement (`Test-PnhModelFit`)

The window starts Ollama, loads the chosen model with the context length it will use and lets it generate 48 tokens
("Count from 1 to 60"). Then it reads `/api/ps`. The model passes when there is no error and (`Get-PnhFitThreshold`):

| Tier | Minimum speed | On the GPU (only when chosen for the GPU) |
|---|---|---|
| 1–2 (and models outside the catalogue) | 5 tokens per second (a 300-token round takes about a minute) | not checked |
| 3 | 10 tokens per second | at least 90 % (`size_vram / size`) |
| 4 | 15 tokens per second (thinking rounds are long) | at least 90 %, except `partialOffload` models |

On the CPU path only the speed counts. Below 90 % on the GPU, Ollama has moved layers to the CPU (VRAM used by another
program, or `minVramGB` too low), which costs far more than the short test shows. The speed values are set from the
catalogue's reasoning, not yet from measurements on real PCs. If the model does not pass, the next candidate is tried
with its own context length (sent per request as `num_ctx`, so Ollama is not restarted). If none passes, the window
says the computer is too slow. Loading a large model from a USB drive can take a while; the test allows up to 300
seconds.

### Runtime settings

Ollama runs from the drive with per-process environment variables only (`New-PnhOllamaEnvironment`):
`OLLAMA_HOST=127.0.0.1:<free port>`, `OLLAMA_NO_CLOUD=1`, `OLLAMA_MODELS=<drive>\PlugNHeal\models`,
`OLLAMA_CONTEXT_LENGTH=<ctx>`, `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_KEEP_ALIVE=30m`,
`OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_NOPRUNE=1`, `USERPROFILE`/`HOME` on the drive. Chat
requests use temperature 0 and send the `num_ctx` of the model in use (`OLLAMA_CONTEXT_LENGTH` is only the default of
the first choice).

## 3. Licences

| Model family | Licence | Checked in |
|---|---|---|
| Qwen3.5 (2B, 4B, 9B) | Apache-2.0, "Copyright 2026 Alibaba Cloud" | licence layer of the registry manifest; Hugging Face cards [Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B), [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), [Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B) |
| Qwen3.8 (27B) | Apache-2.0, "Copyright 2026 Alibaba Cloud" | registry licence layer; [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) |
| Qwen3.6 (35B-A3B) | Apache-2.0 (the registry licence layer has the unfilled copyright template line) | registry licence layer; [Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) |

The builder copies each model's licence layer to `PlugNHeal\licenses\models\` on the drive. See also
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

**Rule for the default catalogue: only Apache-2.0 or MIT.** Models with use restrictions or extra duties are left
out, so that a built drive can be passed on without surprises. Examples from the research that were **not** taken:

| Model | Why not |
|---|---|
| `lfm3:1.7b` | strong tool use, but LFM Open License v1.0 (commercial use only below 10 million USD revenue); replaced by `qwen3.5:2b` |
| `qwen3:1.7b`, `qwen3:4b` | Ollama template bug #14601 (tool definitions rendered as Go structs); Qwen3.5+ uses built-in renderers instead |
| `gpt-oss:20b` | HTTP 500 with long string arguments (#17638), weak in agent benchmarks |
| `muse-glimmer:30b` | usage policy "not intended for individuals under the age of 18"; Windows tool-calling crash (#19439) |
| `gemma4` models | Apache-2.0 and good German, but weaker agent results and open tool-calling bugs (#18468, #18275) |
| `qwen3.8:27b-nvfp4`, `-mlx`, `-mxfp8` | not GGUF (MLX engine); not usable with Ollama on Windows/NVIDIA |

## 4. Changing the catalogue

1. **Pick a tag.** A fixed quantisation tag (for example `name:9b-q4_K_M`), never a floating tag like `latest` or
   `9b`: floating tags change and their size depends on the client. The model must support tools
   (<https://ollama.com/search?c=tools>), be GGUF (manifest layer `application/vnd.ollama.image.model`, file starts
   with `GGUF`), have a licence that fits the rule above, and a `requires` value in its config blob that is not newer
   than the pinned Ollama version in [`builder/versions.json`](../builder/versions.json) (0.40.15).
2. **Measure the size.** `bytes` = config size + all layer sizes of the registry manifest:

   ```bash
   curl -sL -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
     https://registry.ollama.ai/v2/library/qwen3.5/manifests/4b-q4_K_M \
     | python3 -c 'import json,sys; m=json.load(sys.stdin); print(m["config"]["size"] + sum(l["size"] for l in m["layers"]))'
   # 3324173934
   ```

   Both builders re-measure every model and refuse to build when the catalogue differs by more than 1 %
   (`sizeTolerancePercent`).
3. **Work out the memory needs.** `minVramGB`: weights + projector + KV cache at `ctx` (q8_0) + about 0.5–1 GiB of
   buffers. `minRamGB`: the same at 16k context plus about 1 GiB. Prefer measurements (`ollama ps`, `size_vram`)
   over estimates.
4. **Fill in the entry** with all fields (`id`, `tag`, `bytes`, `license`, `tier`, `minVramGB`, `minRamGB`, `ctx`,
   `think`, `freeShell`, `default`, `family`, `parameters`, `quant`, `gguf`, `modelMediaType`, `modelDigest`,
   `modelBytes`, `projectorBytes`, `requires`, `notes`). Give `freeShell: true` only to large models that are
   reliable at multi-step tool use.
5. **Update the profiles** (`models` and the `bytes` sum of each profile).
6. **Run the tests:** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/Models.Tests.ps1`, and the same for
   `tests/Builder.Tests.ps1`. They check the fields, the size arithmetic and the profile sums.
7. **Try it on real hardware** of the class it is meant for, and note the result (load time, tokens per second,
   `size_vram`) in the pull request.
8. **Update the docs:** this page, [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) and both READMEs ("Which AI
   model will my PC use?").

## 5. Known gaps

- The `think` defaults and the 8 GB class (4B on the GPU versus 9B with partial offload) are not yet A/B tested.
- `qwen3.8` defaults to a high reasoning effort; how Ollama's `think` flag maps to it is unverified.
- AMD cards count as GPUs, but the Windows ZIP of Ollama 0.40.15 contains CUDA and Vulkan back-ends and no ROCm
  libraries, so AMD cards would run through Vulkan. This has not been measured.
- The speed minimums (5/10/15 tokens per second) and the 90 % GPU share have not been checked on real PCs yet.
- Small models make mistakes in multi-step tool use. The agent compensates (only candidate actions, validation,
  verified summary), see [SAFETY.md](SAFETY.md#honest-limits).

## 6. Sources

All retrieved on 9 November 2026. More, including benchmark sources, in [research/modelle.md](research/modelle.md).

- Ollama library and tags: <https://ollama.com/library/qwen3.5/tags>, <https://ollama.com/library/qwen3.6/tags>,
  <https://ollama.com/library/qwen3.8/tags>; models with tool support: <https://ollama.com/search?c=tools>
- Registry manifests and config blobs: `https://registry.ollama.ai/v2/library/<name>/manifests/<tag>`
- Model cards: <https://huggingface.co/Qwen/Qwen3.5-2B>, <https://huggingface.co/Qwen/Qwen3.5-9B>,
  <https://huggingface.co/Qwen/Qwen3.8-27B>, <https://huggingface.co/Qwen/Qwen3.6-35B-A3B>
- Ollama context length: <https://docs.ollama.com/context-length>
- Ollama issues: [#14601](https://github.com/ollama/ollama/issues/14601),
  [#16383](https://github.com/ollama/ollama/issues/16383), [#17638](https://github.com/ollama/ollama/issues/17638),
  [#17778](https://github.com/ollama/ollama/issues/17778), [#18468](https://github.com/ollama/ollama/issues/18468),
  [#19439](https://github.com/ollama/ollama/issues/19439)
