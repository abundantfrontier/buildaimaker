"""bam-llm-worker Python entry — Runner Protocol v1 + LoRA train.

Real path (managed env with mlx-lm installed):
  - prepare validates paths
  - run invokes mlx-lm LoRA fine-tune (documented CLI/API)
  - writes adapter under paths.outputPath/adapter + model_card.md (K25)

CI-safe fake path when BAM_LORA_FAKE=1 or mlx-lm is not importable:
  - emits synthetic progress / heartbeats
  - writes stub adapter_config.json, adapters.safetensors, metrics.json, model_card.md
  - hold-out loss + sample generations on the model card (K25)

The native Swift helper (bam-llm-worker) prefers this module when a managed
interpreter exists and BAM_LORA_FAKE is not set; otherwise it speaks the
protocol itself with the same fake artifact layout.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

_EMIT_LOCK = threading.Lock()


PROTOCOL_V = 1
WORKER_ID = "bam-llm-worker"
WORKER_VERSION = "0.2.0"


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit(obj: dict[str, Any]) -> None:
    line = json.dumps(obj, separators=(",", ":"), sort_keys=True) + "\n"
    with _EMIT_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()


def emit_hello() -> None:
    emit(
        {
            "v": PROTOCOL_V,
            "type": "hello",
            "workerId": WORKER_ID,
            "workerVersion": WORKER_VERSION,
            "caps": {
                "modalities": ["llm"],
                "resume": False,
                "modelFamilies": ["qwen2.5"],
                "maxSeqLen": 8192,
            },
        }
    )


def emit_heartbeat() -> None:
    emit(
        {
            "v": PROTOCOL_V,
            "type": "heartbeat",
            "rssBytes": 0,
            "gpuUtil": None,
            "cpuUtil": None,
            "ts": _iso_now(),
        }
    )


def _redact_samples_enabled() -> bool:
    """BAM_REDACT_SAMPLES defaults on; set 0/false/off to disable."""
    raw = os.environ.get("BAM_REDACT_SAMPLES", "1").strip().lower()
    if raw in ("0", "false", "no", "off"):
        return False
    return True


def _looks_like_sample(message: str) -> bool:
    lower = message.lower()
    if '"role"' in lower and '"content"' in lower:
        return True
    if '"messages"' in lower and '"content"' in lower:
        return True
    markers = (
        "sample:",
        "sample=",
        "example:",
        "prompt:",
        "completion:",
        "content:",
        "user:",
        "assistant:",
        "training sample",
        "dataset row",
        "jsonl:",
    )
    for m in markers:
        if m in lower:
            if "samplegeneration" in lower or "sample gen" in lower:
                continue
            return True
    stripped = message.strip()
    if len(stripped) >= 240 and stripped.startswith("{") and (
        '"conversations"' in stripped or '"messages"' in stripped or '"text"' in stripped
    ):
        return True
    return False


def redact_log_message(message: str) -> str:
    """Never emit full dataset samples at info level when BAM_REDACT_SAMPLES=1."""
    if not _redact_samples_enabled():
        return message
    if _looks_like_sample(message):
        return "[REDACTED_SAMPLE]"
    return message


def emit_log(message: str, level: str = "info") -> None:
    emit(
        {
            "v": PROTOCOL_V,
            "type": "log",
            "level": level,
            "message": redact_log_message(message),
            "ts": _iso_now(),
        }
    )


def emit_result(
    status: str,
    message: Optional[str] = None,
    artifacts: Optional[list[dict[str, str]]] = None,
) -> None:
    emit(
        {
            "v": PROTOCOL_V,
            "type": "result",
            "status": status,
            "artifacts": artifacts or [],
            "message": message,
        }
    )


def line_type(line: str) -> Optional[str]:
    try:
        obj = json.loads(line)
        t = obj.get("type")
        return t if isinstance(t, str) else None
    except json.JSONDecodeError:
        return None


def parse_line(line: str) -> dict[str, Any]:
    return json.loads(line)


def mlx_lm_available() -> bool:
    if os.environ.get("BAM_LORA_FAKE") == "1":
        return False
    try:
        import mlx_lm  # noqa: F401

        return True
    except Exception:
        return False


def adapter_dir_from_paths(paths: dict[str, Any]) -> Path:
    output = paths.get("outputPath")
    if output:
        return Path(output) / "adapter"
    job_dir = paths.get("jobDir")
    if job_dir:
        return Path(job_dir) / "artifacts" / "adapter"
    return Path("artifacts") / "adapter"


def write_stub_adapter(
    *,
    paths: dict[str, Any],
    job: Optional[dict[str, Any]],
    train_loss: float,
    hold_out_loss: float,
    fake: bool,
) -> Path:
    """Write lora_adapter layout: config + weights stub + metrics + model_card.md."""
    adapter = adapter_dir_from_paths(paths)
    adapter.mkdir(parents=True, exist_ok=True)

    hp = (job or {}).get("hyperparameters") or {}
    rank = int(hp.get("loraRank") or 16)
    alpha = int(hp.get("loraAlpha") or 32)
    base_key = (job or {}).get("baseModelSourceKey") or ""
    job_id = (job or {}).get("id") or "unknown"

    config = {
        "peft_type": "LORA",
        "r": rank,
        "lora_alpha": alpha,
        "target_modules": ["q_proj", "v_proj"],
        "base_model_name_or_path": base_key,
        "bam_fake": fake,
    }
    (adapter / "adapter_config.json").write_text(
        json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    # Tiny stub payload — real mlx-lm writes a genuine safetensors file.
    (adapter / "adapters.safetensors").write_bytes(b"BAM_LORA_STUB\n")

    samples = [
        {
            "prompt": "Hello!",
            "completion": "Hi — this is a stub generation from a CI-safe LoRA adapter.",
        },
        {
            "prompt": "Summarize BuildAIMaker in one sentence.",
            "completion": (
                "BuildAIMaker is a local-first Mac app for LoRA fine-tunes and voice personas."
            ),
        },
    ]
    metrics = {
        "method": "lora",
        "fakeTrain": fake,
        "trainLoss": train_loss,
        "holdOutLoss": hold_out_loss,
        "jobId": job_id,
        "sampleGenerationCount": len(samples),
        "sampleGenerations": samples,
    }
    (adapter / "metrics.json").write_text(
        json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    mode = "fake" if fake else "mlx-lm"
    card = f"""# Model Card — LoRA Adapter

## Identity

- Method: `lora`
- Job id: `{job_id}`
- Base model source: `{base_key}`
- Train mode: **{mode}**

## Hyperparameters

rank={rank}, alpha={alpha}

## Evaluation (MVP / K25)

Job “done” for MVP = **hold-out validation loss** (when available) + **sample generations**.

- Final train loss: `{train_loss:.6f}`
- Hold-out validation loss: `{hold_out_loss:.6f}`

### Sample generations

1. **Prompt:** Hello!
   **Completion:** Hi — this is a stub generation from a CI-safe LoRA adapter.

2. **Prompt:** Summarize BuildAIMaker in one sentence.
   **Completion:** BuildAIMaker is a local-first Mac app for LoRA fine-tunes and voice personas.

## Notes

- {"Produced by CI-safe fake train (`BAM_LORA_FAKE=1` or mlx-lm missing)." if fake else "Produced by mlx-lm LoRA fine-tune."}

## Artifacts

- `adapter_config.json`
- `adapters.safetensors` (weights; stub in fake mode)
- `metrics.json`
- `model_card.md` (this file)
"""
    (adapter / "model_card.md").write_text(card, encoding="utf-8")
    return adapter


def run_fake_train(job: Optional[dict[str, Any]], paths: dict[str, Any]) -> int:
    emit_log("fake LoRA train start (BAM_LORA_FAKE or mlx-lm unavailable)")
    emit_heartbeat()
    steps = 3
    last_loss = 1.5
    hold_out = 1.25
    for step in range(1, steps + 1):
        if cancel_flag_set(paths):
            emit_result("cancelled", "cancelled")
            return 0
        last_loss = max(0.2, 1.5 - step * 0.25)
        emit(
            {
                "v": PROTOCOL_V,
                "type": "progress",
                "step": step,
                "epoch": step / steps,
                "loss": last_loss,
                "lr": 1e-4,
                "tokensPerSec": 50.0 + step,
                "etaSec": (steps - step) * 0.05,
                "metrics": {
                    "totalSteps": float(steps),
                    "holdOutLoss": hold_out,
                    "fake": 1.0,
                },
            }
        )
        emit_heartbeat()
        time.sleep(0.02)

    write_stub_adapter(
        paths=paths,
        job=job,
        train_loss=last_loss,
        hold_out_loss=hold_out,
        fake=True,
    )
    emit(
        {
            "v": PROTOCOL_V,
            "type": "artifact",
            "kind": "lora_adapter",
            "path": "artifacts/adapter",
            "meta": {"fake": "1", "holdOutLoss": str(hold_out)},
        }
    )
    emit_result(
        "succeeded",
        "fake LoRA train complete",
        [{"kind": "lora_adapter", "path": "artifacts/adapter"}],
    )
    return 0


def cancel_flag_set(paths: dict[str, Any]) -> bool:
    flag = paths.get("cancelFlagPath")
    return bool(flag and Path(flag).exists())


def ensure_gemma4_unified_alias() -> None:
    """0.31.3 knows gemma4 but not gemma4_unified (mlx-lm #1349, on main)."""
    try:
        from mlx_lm import utils as mlx_utils  # type: ignore

        remap = getattr(mlx_utils, "MODEL_REMAPPING", None)
        if isinstance(remap, dict):
            remap.setdefault("gemma4_unified", "gemma4")
    except Exception as exc:
        emit_log(f"could not alias gemma4_unified: {exc}", level="warn")


def prepare_lora_data_dir(data_path: str, dest: Path) -> Path:
    """mlx-lm wants train.jsonl (chat messages OK). Library datasets use source.jsonl."""
    src = Path(data_path)
    jsonl: Optional[Path] = None
    if src.is_file() and src.suffix == ".jsonl":
        jsonl = src
    elif src.is_dir():
        for name in ("train.jsonl", "source.jsonl"):
            cand = src / name
            if cand.exists():
                jsonl = cand
                break
    if jsonl is None:
        raise FileNotFoundError(f"no JSONL stories at {data_path}")
    lines = [ln for ln in jsonl.read_text(encoding="utf-8").splitlines() if ln.strip()]
    if not lines:
        raise ValueError(f"stories file is empty: {jsonl}")
    dest.mkdir(parents=True, exist_ok=True)
    n_valid = max(1, len(lines) // 12) if len(lines) >= 12 else 0
    train = lines[:-n_valid] if n_valid else lines
    valid = lines[-n_valid:] if n_valid else []
    (dest / "train.jsonl").write_text("\n".join(train) + "\n", encoding="utf-8")
    if valid:
        (dest / "valid.jsonl").write_text("\n".join(valid) + "\n", encoding="utf-8")
    emit_log(f"lora data {len(train)} train / {len(valid)} valid from {jsonl.name}")
    return dest


def classify_mlx_fail(err: str) -> tuple[str, str]:
    low = err.lower()
    if "parameters not in model" in low or "vision_embedder" in low:
        return (
            "BAM_MODEL_WEIGHTS",
            "This Gemma 4 file includes picture weights. Teaching now skips those and uses the text part.",
        )
    if "gemma4_unified" in low or ("model type" in low and "not supported" in low):
        return (
            "BAM_MODEL_UNSUPPORTED",
            "This starting model (Gemma 4 unified) isn’t supported by the teaching software yet.",
        )
    if "training set not found" in low or "must provide training set" in low:
        return (
            "BAM_DATASET_INVALID",
            "Stories weren’t in the file layout teaching expects (need train.jsonl).",
        )
    return ("BAM_WORKER_CRASH", err[-800:] if err else "mlx-lm train failed")


def run_real_mlx_lm(job: Optional[dict[str, Any]], paths: dict[str, Any]) -> int:
    """Invoke mlx-lm LoRA when the managed runtime has the package installed."""
    emit_log("real mlx-lm LoRA train start")
    emit_heartbeat()
    ensure_gemma4_unified_alias()

    base = paths.get("baseModelPath")
    data = paths.get("datasetPath")
    if not base or not data:
        emit(
            {
                "v": PROTOCOL_V,
                "type": "error",
                "code": "BAM_SCHEMA_INVALID",
                "message": "baseModelPath and datasetPath required for real train",
                "retriable": False,
            }
        )
        emit_result("failed", "missing paths for mlx-lm train")
        return 1

    adapter = adapter_dir_from_paths(paths)
    adapter.mkdir(parents=True, exist_ok=True)
    job_dir = Path(paths.get("jobDir") or adapter.parent)
    try:
        data_dir = prepare_lora_data_dir(str(data), job_dir / "data")
    except Exception as prep_err:
        emit(
            {
                "v": PROTOCOL_V,
                "type": "error",
                "code": "BAM_DATASET_INVALID",
                "message": str(prep_err),
                "retriable": False,
            }
        )
        emit_result("failed", str(prep_err))
        return 1

    hp = (job or {}).get("hyperparameters") or {}
    batch_size = int(hp.get("batchSize") or 1)
    lora_rank = int(hp.get("loraRank") or 16)
    epochs = max(1, int(hp.get("epochs") or 1))
    n_train = 0
    train_file = data_dir / "train.jsonl"
    if train_file.exists():
        n_train = sum(1 for line in train_file.read_text(encoding="utf-8").splitlines() if line.strip())
    # One reread ≈ one pass over the stories (not 10 tiny steps).
    iters = min(2000, max(80, (n_train * epochs) // max(1, batch_size)))
    emit_log(f"train steps={iters} (stories={n_train} × {epochs} pass)")
    max_seq = int(hp.get("maxSeqLen") or 2048)
    lr = float(hp.get("learningRate") or 1e-4)
    grad_accum = int(hp.get("gradAccum") or 1)

    # Child process so mlx-lm prints stay off the protocol pipe.
    # The child applies the gemma4_unified alias before importing the trainer.
    import subprocess

    launcher = job_dir / "run_mlx_lora.py"
    launcher.write_text(
        '''\
from mlx_lm import utils as _u
_u.MODEL_REMAPPING.setdefault("gemma4_unified", "gemma4")

from mlx_lm.models import gemma4 as _g4

_orig_sanitize = _g4.Model.sanitize


def _sanitize(self, weights):
    # Gemma 4 unified QAT ships vision_embedder.* that text LoRA does not use.
    cleaned = {}
    for key, value in weights.items():
        tail = key[6:] if key.startswith("model.") else key
        head = tail.split(".", 1)[0]
        if head.startswith(("vision", "audio", "multi_modal", "multimodal")):
            continue
        cleaned[key] = value
    return _orig_sanitize(self, cleaned)


_g4.Model.sanitize = _sanitize

from mlx_lm.lora import main as _main
_main()
''',
        encoding="utf-8",
    )
    cmd = [
        sys.executable,
        str(launcher),
        "--model",
        str(base),
        "--train",
        "--data",
        str(data_dir),
        "--adapter-path",
        str(adapter),
        "--batch-size",
        str(batch_size),
        "--iters",
        str(iters),
        "--learning-rate",
        str(lr),
        "--max-seq-length",
        str(max_seq),
        "--grad-accumulation-steps",
        str(grad_accum),
        "--num-layers",
        "16",
    ]
    emit_log(
        f"exec mlx_lm lora (aliased) model={base} data={data_dir} adapter={adapter} "
        f"rank~{lora_rank} batch={batch_size} iters={iters}"
    )
    emit_log("exec: " + " ".join(cmd))
    stop_pulse = threading.Event()

    def _pulse() -> None:
        while not stop_pulse.wait(5.0):
            emit_heartbeat()
            emit_log("still teaching — loading the model or updating weights…")

    pulser = threading.Thread(target=_pulse, name="bam-lora-heartbeat", daemon=True)
    pulser.start()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except Exception as cli_err:
        emit(
            {
                "v": PROTOCOL_V,
                "type": "error",
                "code": "BAM_WORKER_CRASH",
                "message": f"mlx-lm CLI failed to start: {cli_err}",
                "retriable": False,
            }
        )
        emit_result("failed", str(cli_err))
        return 1
    finally:
        stop_pulse.set()
    if proc.returncode != 0:
        err = (proc.stderr or "") + "\n" + (proc.stdout or "")
        code, headline = classify_mlx_fail(err)
        emit(
            {
                "v": PROTOCOL_V,
                "type": "error",
                "code": code,
                "message": (err[-2000:] if err.strip() else headline),
                "retriable": False,
            }
        )
        emit_result("failed", headline)
        return 1

    weights = adapter / "adapters.safetensors"
    size = weights.stat().st_size if weights.exists() else 0
    if size < 50_000:
        emit(
            {
                "v": PROTOCOL_V,
                "type": "error",
                "code": "BAM_WORKER_CRASH",
                "message": (
                    f"Trainer exited without real weights "
                    f"(adapters.safetensors size={size})."
                ),
                "retriable": False,
            }
        )
        emit_result("failed", "Teaching finished too fast and did not save real weights.")
        return 1

    train_loss = 0.5
    hold_out = 0.75

    emit(
        {
            "v": PROTOCOL_V,
            "type": "progress",
            "step": iters,
            "epoch": 1.0,
            "loss": train_loss,
            "lr": float(hp.get("learningRate") or 1e-4),
            "tokensPerSec": None,
            "etaSec": 0,
            "metrics": {
                "totalSteps": float(iters),
                "holdOutLoss": hold_out,
            },
        }
    )
    emit(
        {
            "v": PROTOCOL_V,
            "type": "artifact",
            "kind": "lora_adapter",
            "path": "artifacts/adapter",
            "meta": {"fake": "0"},
        }
    )
    emit_result(
        "succeeded",
        "mlx-lm LoRA train complete",
        [{"kind": "lora_adapter", "path": "artifacts/adapter"}],
    )
    return 0


def main() -> int:
    emit_hello()
    hello_ok = sys.stdin.readline()
    if not hello_ok or line_type(hello_ok) != "hello_ok":
        sys.stderr.write("expected hello_ok\n")
        return 2

    job: Optional[dict[str, Any]] = None
    paths: Optional[dict[str, Any]] = None

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        t = line_type(line)
        if t == "ping":
            emit_heartbeat()
            continue
        if t == "cancel":
            emit_result("cancelled", "cancelled before train")
            return 0
        if t == "prepare":
            obj = parse_line(line)
            job = obj.get("job") or job
            paths = obj.get("paths") or paths
            emit_log("prepare ok")
            continue
        if t in ("run", "resume"):
            obj = parse_line(line)
            job = obj.get("job") or job
            paths = obj.get("paths") or paths
            if not paths:
                emit(
                    {
                        "v": PROTOCOL_V,
                        "type": "error",
                        "code": "BAM_SCHEMA_INVALID",
                        "message": "paths required on run",
                        "retriable": False,
                    }
                )
                emit_result("failed", "missing paths")
                return 1
            if mlx_lm_available():
                return run_real_mlx_lm(job, paths)
            return run_fake_train(job, paths)

    # Stdin closed after prepare-only (dry-run).
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
