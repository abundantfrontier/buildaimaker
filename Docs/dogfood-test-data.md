# Dogfood & test data

Public and in-repo data you can use to exercise BuildAIMaker without inventing files from scratch.

**Last updated:** 2026-07-19

## What the app accepts today

### Text datasets (Datasets UI)

| Format | Shape | Notes |
|--------|--------|--------|
| **OpenAI messages JSONL** | One JSON object per line: `{"messages":[{"role":"system\|user\|assistant","content":"..."}, ...]}` | Preferred |
| **ShareGPT JSONL** | `{"conversations":[{"from":"human\|gpt\|system","value":"..."}, ...]}` | Mapped to user/assistant/system |

- **Copy** import: files under `~/Library/Application Support/BuildAIMaker/datasets/`
- **Reference** import: keeps original path (bookmark when possible)
- Invalid rows surface `BAM_DATASET_INVALID` with line-level messages

### Models

| Source | How |
|--------|-----|
| **Tiny fixture** | Models → **Install fixture model** (offline, ~KB stub — not real weights) |
| **Catalog entries** | Qwen2.5 0.5B / 1.5B / 3B MLX (need real weights on disk or HF path) |
| **HF (optional)** | Behind `ff.hfHubDownload`; needs token for gated models |

### Voice

- Short clean **WAV** (~5–60 s speech) + **consent attestation** (self / third-party rules)
- CI uses **stub clone** unless full F5 runtime is installed
- Prefer **your own voice** or **explicitly licensed** samples (see ethics below)

### Train / playground

- **Fake LoRA** (default dogfood): no multi-GB runtime; still exercises materialize + artifacts + cards  
- **Real mlx-lm**: managed Python install + real MLX weights + larger dataset  
- Playground: base ± adapter; Talk: STT/TTS stubs until real backends installed  

---

## In-repo fixtures (start here)

After pull, these live under the repo:

| Path | Use |
|------|-----|
| `Workers/fixtures/datasets/socrates-mini.openai.jsonl` | **8** Socratic-style OpenAI-messages rows — import in Datasets |
| `Workers/fixtures/datasets/sharegpt-mini.jsonl` | **2** ShareGPT rows — format smoke test |
| `Packages/BAMDatasets/Tests/.../Fixtures/valid_*.jsonl` | Unit-test goldens (also valid imports) |
| `Workers/fixtures/models/tiny-qwen-mlx/` | Stub model layout (install via UI) |

### Quick path in the app

1. **Datasets** → Import → choose `socrates-mini.openai.jsonl` (copy mode)  
2. **Models** → Install fixture model  
3. **Train** → pick dataset + model → **Validate & dry-run** (then optional **Train LoRA** fake)  
4. **Playground** → chat with base / adapter if present  
5. **Voices** → consent + short self recording (or silent WAV only for UI path)  
6. **Personas** → compose LLM + voice when both exist  

---

## Public text datasets (download yourself)

Use for **larger** fine-tunes once real MLX models work. Convert to OpenAI messages or ShareGPT JSONL if needed.

### Small / easy (good for Mac dogfood)

| Dataset | Why useful | License / notes |
|---------|------------|-----------------|
| [Databricks Dolly 15k](https://huggingface.co/datasets/databricks/databricks-dolly-15k) | Instruction-following; well known | CC-BY-SA — share-alike |
| [OpenAssistant OASST1](https://huggingface.co/datasets/OpenAssistant/oasst1) | Multi-turn chat trees | Apache-2.0 |
| [UltraChat / ShareGPT-style dumps](https://huggingface.co/datasets/stingning/ultrachat) | Multi-turn assistant | Check card; often research-only |
| [Alpaca](https://huggingface.co/datasets/tatsu-lab/alpaca) | Classic instruction set | CC-BY-NC (non-commercial) |
| [No Robots](https://huggingface.co/datasets/HuggingFaceH4/no_robots) | High-quality human chats | Check card |

### Philosophy / “Talk to Socrates” flavor

There is no single official “Socrates chat JSONL.” Practical options:

1. **Use `socrates-mini.openai.jsonl`** in-repo for UI/pipeline tests.  
2. **Public-domain Plato** (e.g. [Project Gutenberg — Plato](https://www.gutenberg.org/ebooks/author/93)) → convert dialogues to `user`/`assistant` turns (you write the converter; content is PD in many jurisdictions).  
3. **Synthesize** more Socratic turns with any chat model, then import as JSONL (watch licenses of the generator’s terms).

### Hugging Face download pattern

```bash
# Example: peek at a dataset (needs `pip install datasets` or use the website Export)
# Prefer downloading a small parquet/json and converting to messages JSONL.
```

Website: open the dataset → **Files** → download a JSON/JSONL sample, or use the Datasets library to map fields into:

```json
{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"..."}]}
```

---

## Public models (real train/infer)

| Model | Where | Notes |
|-------|--------|------|
| Qwen2.5 Instruct 0.5B–3B **MLX 4-bit** | [mlx-community on Hugging Face](https://huggingface.co/mlx-community) | Matches catalog `sourceKey`s |
| Other MLX community ports | same | Must match chat template registry |

Place under:

`~/Library/Application Support/BuildAIMaker/models/base/<id>/`

or use the app’s HF install path when enabled.

**Hardware:** design minimum **16 GB** unified for train features; 0.5B–1.5B is the realistic laptop range for first real LoRA.

---

## Voice samples (careful)

| Source | Notes |
|--------|--------|
| **Your own mic** | Best for consent path (`self`) |
| [LibriSpeech](https://www.openslr.org/12) / [LJ Speech](https://keithito.com/LJ-Speech-Dataset/) | Research audio; licenses allow many research uses — **not** “celebrity clone” |
| [Mozilla Common Voice](https://commonvoice.mozilla.org/) | CC-0 clips; good for short refs |

**Do not** use celebrity or third-party voices without clear rights + app consent attestation (`third_party` + typed fields). Product policy (K20): no non-consensual third parties; no celebrity catalog.

For clone dogfood without real F5: any short mono WAV exercises **UI + consent + job materialize**; synthesis may be stub.

---

## Capability matrix (what each dataset exercises)

| Data | Import validate | Dry-run | Fake LoRA | Real LoRA | Playground | Voice | Persona |
|------|-----------------|---------|-----------|-----------|------------|-------|---------|
| `socrates-mini.openai.jsonl` | ✅ | ✅ | ✅ | ⚠️ need real model | ✅ after train | — | text-only / full |
| `sharegpt-mini.jsonl` | ✅ | ✅ | ✅ | ⚠️ | ✅ | — | |
| Dolly / OASST (converted) | ✅ | ✅ | ✅ | ✅ | ✅ | — | |
| Tiny fixture model | — | ✅ | ✅ | ❌ weights stub | echo/stub | — | |
| Real Qwen MLX 0.5B–1.5B | — | ✅ | ✅ | ✅ | ✅ | — | |
| Self WAV + consent | — | — | — | — | — | ✅ | full pack |

---

## Optional: one-liner to expand Socratic data

If you have `python3` and want more synthetic rows for pipeline stress (not high literary quality):

```bash
# Manually append more OpenAI-messages lines to socrates-mini, or write a small script
# that emits {"messages":[...]} lines. Keep UTF-8, one JSON object per line, no trailing commas.
```

---

## Related

- [design-buildaimaker.md](./design-buildaimaker.md) — M1–M8 success metrics  
- [adr/0001-llm-runtime.md](./adr/0001-llm-runtime.md) — real vs fake train  
- [adr/0002-voice-engine.md](./adr/0002-voice-engine.md) — voice runtime  
