# Third-party notices

Plug'n'Heal's repository contains **none** of the components listed here. It contains only its own scripts,
catalogues and documentation (Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE)).

The builder (`BUILD.cmd` / `builder/Build-Drive.ps1` on Windows, `builder/build-drive.sh` on Linux and macOS)
downloads the components below **from their original sources** onto the SSD. Whoever builds a drive receives them
directly from those sources, under their licences. The builder also copies this file and the licence texts to the
drive:

| On the drive | Content |
|---|---|
| `PlugNHeal\licenses\THIRD-PARTY-NOTICES.md` | this file |
| `PlugNHeal\licenses\ollama-LICENSE.txt` | Ollama's licence, fetched from the pinned release tag |
| `PlugNHeal\licenses\runtime\*.txt` | the licence files shipped inside the Ollama ZIP (`lib\ollama\*LICENSE*`) |
| `PlugNHeal\licenses\models\<model>.LICENSE.txt` | the licence layer of each model's Ollama registry manifest |

Versions, URLs and checksums are pinned in [builder/versions.json](builder/versions.json) (runtime) and
[src/catalog/models.json](src/catalog/models.json) (models). Checked on 9 November 2026. This is a list for
orientation, not legal advice.

## 1. Ollama runtime

| | |
|---|---|
| Component | Ollama 0.40.15, Windows x64 build (`ollama-windows-amd64.zip`) |
| Source | <https://github.com/ollama/ollama/releases/tag/v0.40.15> |
| Download | `https://github.com/ollama/ollama/releases/download/v0.40.15/ollama-windows-amd64.zip`, 1,614,941,966 bytes, SHA-256 `9ca74a7ab66ec86870b1eecac7df160df08dc4e3a291ab5d2d59bcf9310221c6` |
| Licence | MIT, "Copyright (c) Ollama": <https://github.com/ollama/ollama/blob/v0.40.15/LICENSE> |
| On the drive | `PlugNHeal\runtime\ollama\` (75 files, 2,263,717,391 bytes unpacked) |

### 1.1 Components inside the Ollama ZIP that bring their own licence file

These files are in `lib/ollama/` of the ZIP. The builder copies them to `PlugNHeal\licenses\runtime\`.

| Licence file in the ZIP | Covers | Licence |
|---|---|---|
| `LLAMA_CPP_LICENSE` | [llama.cpp](https://github.com/ggml-org/llama.cpp) and [ggml](https://github.com/ggml-org/ggml) (`ggml*.dll`, `libllama*.dll`, `libmtmd.dll`, `llama-server.exe`, `llama-quantize.exe`), "Copyright (c) 2023-2026 The ggml authors" | MIT |
| `LLAMA_CPP_VENDORS_LICENSE` | code vendored by llama.cpp: cpp-httplib (MIT, yhirose), hash-rotate-bits (MIT, William Casarin), sha256 (public domain, Igor Pavlov), xxHash (BSD-2-Clause, Yann Collet), nlohmann/json (MIT, Niels Lohmann), llamafile sgemm (MIT, Mozilla Foundation) | as listed |
| `CPP_HTTPLIB_LICENSE` | [cpp-httplib](https://github.com/yhirose/cpp-httplib), "Copyright (c) 2017 yhirose" | MIT |
| `GO_LICENSE` | Ollama itself and the Go modules it is built from (66 licence and notice entries, for example gin, cobra, golang.org/x/...), each with its own text | various (MIT, BSD, Apache-2.0, ...), see the file |

### 1.2 Components inside the Ollama ZIP without their own licence file

The ZIP also contains the following redistributable libraries of other vendors. The ZIP has no licence file for
them, so the builder cannot copy one; their terms are linked here.

| Files in the ZIP | Vendor | Terms |
|---|---|---|
| `lib/ollama/cuda_v12/`: `cudart64_12.dll`, `cublas64_12.dll`, `cublasLt64_12.dll`; `lib/ollama/cuda_v13/`: `cudart64_13.dll`, `cublas64_13.dll`, `cublasLt64_13.dll`, `nvrtc64_130_0.dll`, `nvrtc64_130_0.alt.dll`, `nvrtc-builtins64_130.dll`, `nvJitLink_130_0.dll` | NVIDIA (CUDA runtime, cuBLAS, NVRTC, nvJitLink) | [NVIDIA CUDA Toolkit EULA](https://docs.nvidia.com/cuda/eula/index.html), Attachment A lists these libraries as redistributable. They may only be passed on as part of an application (here: Ollama), not on their own. |
| `msvcp140*.dll`, `vcruntime140*.dll`, `concrt140.dll`, `vccorlib140.dll` (version 14.44.35211.0) in `cuda_v12/`, `cuda_v13/` and `vulkan/` | Microsoft (Visual C++ runtime) | Microsoft Visual C++ Redistributable licence terms: [redistributing Visual C++ files](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files), [Visual Studio licence terms](https://visualstudio.microsoft.com/license-terms/) |
| `lib/ollama/libc++.dll`, `libunwind.dll`, `libomp.dll` (built with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw), clang 18.1.8) | LLVM project | Apache-2.0 WITH LLVM-exception: <https://llvm.org/LICENSE.txt> |
| `lib/ollama/libwinpthread-1.dll` ("POSIX WinThreads for Windows", "Copyright (C) MinGW-W64 Project Members 2010-2023") | MinGW-w64 project | [winpthreads COPYING](https://github.com/mingw-w64/mingw-w64/blob/master/mingw-w64-libraries/winpthreads/COPYING) (MIT-style) |

`ggml-vulkan.dll` uses the Vulkan driver that is already installed with the graphics driver; no Vulkan runtime is
shipped.

## 2. Language models

All models of the default catalogue are licensed under the **Apache License 2.0**. This was checked in two places:
the licence layer of each model's manifest in the Ollama registry (`registry.ollama.ai`), which the builder
copies to the drive, and the model card on Hugging Face (licence field `apache-2.0`).

| Model tag | In profile | Size (bytes) | Licence | Copyright line in the licence layer | Model card |
|---|---|---|---|---|---|
| [`qwen3.5:2b-q4_K_M`](https://ollama.com/library/qwen3.5:2b-q4_K_M) | small, standard, full | 1,945,781,358 | Apache-2.0 | Copyright 2026 Alibaba Cloud | [Qwen/Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B) |
| [`qwen3.5:4b-q4_K_M`](https://ollama.com/library/qwen3.5:4b-q4_K_M) | small, standard, full | 3,324,173,934 | Apache-2.0 | Copyright 2026 Alibaba Cloud | [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) |
| [`qwen3.5:9b-q4_K_M`](https://ollama.com/library/qwen3.5:9b-q4_K_M) | standard, full | 6,550,825,550 | Apache-2.0 | Copyright 2026 Alibaba Cloud | [Qwen/Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B) |
| [`qwen3.5:9b-q8_0`](https://ollama.com/library/qwen3.5:9b-q8_0) | full | 10,449,218,124 | Apache-2.0 | Copyright 2026 Alibaba Cloud | [Qwen/Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B) |
| [`qwen3.8:27b-q4_K_M`](https://ollama.com/library/qwen3.8:27b-q4_K_M) | standard, full | 17,741,872,132 | Apache-2.0 | Copyright 2026 Alibaba Cloud | [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) |
| [`qwen3.6:35b-a3b-mtp-q4_K_M`](https://ollama.com/library/qwen3.6:35b-a3b-mtp-q4_K_M) | full | 22,621,314,381 | Apache-2.0 | none (the layer contains the unfilled template line) | [Qwen/Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) |

The model files (weights, vision projector, chat template, parameters) are downloaded from the Ollama registry. The
Qwen models are made by the Qwen team of Alibaba Cloud.

## 3. Tools that are part of Windows

At run time Plug'n'Heal uses Windows PowerShell 5.1 and built-in Windows programs (for example `curl.exe` and
`tar.exe` in the builder, `ipconfig`, `netsh`, `sfc`, `DISM` in the repair steps). They are part of Windows, are not
downloaded and are not copied to the drive.

## 4. If you pass on a built drive

- Keep the folder `PlugNHeal\licenses` and this file on the drive.
- The NVIDIA CUDA libraries may only be passed on as part of Ollama, not on their own.
- Delete the folder `PlugNHeal\logs` first: it contains details of the computers the drive was used on.
- Selling drives with software on them can bring obligations of its own (for example product liability). Ask a
  qualified person before you do that.
