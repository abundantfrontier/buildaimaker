# Tiny Qwen MLX fixture

**Offline CI / protocol plumbing only — not a quality model.**

This directory is a **toy** HF/MLX-shaped layout: stub `config.json`, tokenizer metadata, and a tiny placeholder weight file. It is intentionally **not** multi-GB real weights.

| Item | Purpose |
|------|---------|
| `config.json` | Minimal architecture stub (`model_type: qwen2`) |
| `tokenizer*.json` | Stub tokenizer / special tokens for materializer tests |
| `model.safetensors` | Empty placeholder (0 real parameters) |
| `WEIGHTS_NOT_INCLUDED.txt` | Explicit note that real MLX weights are separate |

## Real MLX weights

Download real Qwen2.5 Instruct MLX community builds (or other catalog entries) via the **optional Hugging Face Hub path** (`ff.hfHubDownload`) or outside the app. Install into:

```text
~/Library/Application Support/BuildAIMaker/models/base/<id>/
```

See living catalog: `Catalog/models.json`.

## Offline install

The Models UI **Install fixture model** button (and `ModelInstallService.installFixture`) copies this layout into `models/base/tiny-qwen-mlx-fixture/` with **no network**.

Catalog `sourceKey`: `buildaimaker/tiny-qwen-mlx-fixture`
