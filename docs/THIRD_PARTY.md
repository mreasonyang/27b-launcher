# Third-party components

[README](../README.md)

27B Launcher is an independent client. It downloads the following artifacts on
first-run installation; they are not embedded in the launcher app bundle.
The download manifest is [InstallationCatalog.swift](../Sources/Launcher27B/InstallationCatalog.swift).
Update this document whenever that manifest changes.

## Sources and licenses

| Component | Upstream source at the pinned revision | Upstream license reference |
| --- | --- | --- |
| Prism macOS ARM64 runtime | [Prism llama.cpp release](https://github.com/PrismML-Eng/llama.cpp/releases/tag/prism-b10683-d8f26ee) | [MIT license](https://github.com/PrismML-Eng/llama.cpp/blob/prism-b10683-d8f26ee/LICENSE) |
| Bonsai 2 27B PQ2_0 and Q8_0 vision projector | [Prism ML model repository](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/tree/6ed5e12bf84b7a63069882c91dd9e9218647d17b) | [License](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/blob/6ed5e12bf84b7a63069882c91dd9e9218647d17b/LICENSE) and [NOTICE](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/blob/6ed5e12bf84b7a63069882c91dd9e9218647d17b/NOTICE.txt) |
| OrcaBonsai LoRA | [Continuum AI adapter repository](https://github.com/Continuum-AI-Corp/OrcaBonsai-27B-Uncensored/tree/947a80cd1d3b4f9a97417025e6c2c62223571287) | [Apache-2.0 license](https://github.com/Continuum-AI-Corp/OrcaBonsai-27B-Uncensored/blob/947a80cd1d3b4f9a97417025e6c2c62223571287/LICENSE) |

These references identify upstream licensing; they do not relicense downloaded
artifacts under this project's [MIT license](../LICENSE). Preserve applicable
upstream licenses and notices if you redistribute those artifacts. Review the
actual release contents, including bundled runtime dependencies, before doing so.
The launcher does not claim ownership of upstream names or models.

## Pinned downloads

| Artifact | Version/revision | Bytes |
| --- | --- | ---: |
| `llama-prism-b10683-d8f26ee-bin-macos-arm64.tar.gz` | `prism-b10683-d8f26ee` | 11,663,242 |
| `Ternary-Bonsai-2-27B-PQ2_0.gguf` | `6ed5e12bf84b7a63069882c91dd9e9218647d17b` | 7,206,168,928 |
| `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` | `6ed5e12bf84b7a63069882c91dd9e9218647d17b` | 629,246,976 |
| `bonsai-abliterate-lora.gguf` | `947a80cd1d3b4f9a97417025e6c2c62223571287` | 9,682,464 |

Total expected download: **7,856,761,610 bytes** (about 7.86 GB decimal).
Extracted runtime and temporary/migration files require additional space.

SHA-256 values are checked before newly downloaded artifacts are installed:

```text
0ae163ca2c9cce92470316ed743f76985beea4d5cf31b8dc546711cf6fc8dd35  llama-prism-b10683-d8f26ee-bin-macos-arm64.tar.gz
3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1  Ternary-Bonsai-2-27B-PQ2_0.gguf
6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903  Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
f1669534803d340a496015f5c45125f3437b4d13ec764f40e34488ce83967f42  bonsai-abliterate-lora.gguf
```

SHA-256 digests are verified against this catalog before any downloaded files are installed.

## Compatibility and Model Notes

- **Optimized Runtime**: The launcher pairs Bonsai 2's ternary-weight format (PQ2_0) and Q8_0 vision projector with the pinned Prism `llama.cpp` runtime for optimal Apple Silicon performance.
- **OrcaBonsai LoRA**: The adapter is designed to modify refusal behavior on benign prompts. You can toggle it off or adjust its multiplier (0.5×–2.0×) directly in the dashboard. Changing this setting automatically restarts the local inference server.

