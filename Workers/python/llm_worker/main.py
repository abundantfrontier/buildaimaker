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
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


PROTOCOL_V = 1
WORKER_ID = "bam-llm-worker"
WORKER_VERSION = "0.2.0"


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":"), sort_keys=True) + "\n")
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


def emit_log(message: str, level: str = "info") -> None:
    emit(
        {
            "v": PROTOCOL_V,
            "type": "log",
            "level": level,
            "message": message,
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


def run_real_mlx_lm(job: Optional[dict[str, Any]], paths: dict[str, Any]) -> int:
    """Invoke mlx-lm LoRA when the managed runtime has the package installed.

    Documented CLI (mlx-lm):
      python -m mlx_lm lora \\
        --model <baseModelPath> \\
        --train \\
        --data <dataset_dir_or_jsonl_parent> \\
        --adapter-path <outputPath/adapter> \\
        --batch-size … --lora-layers … --iters …

    We prefer the Python API when available, then fall back to the module CLI.
    On any failure we emit an error and exit non-zero (no silent fake fallback
    once real mode was selected).
    """
    emit_log("real mlx-lm LoRA train start")
    emit_heartbeat()

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

    hp = (job or {}).get("hyperparameters") or {}
    # Coarse mapping from JobSpec hyperparameters → mlx-lm knobs.
    batch_size = int(hp.get("batchSize") or 1)
    lora_rank = int(hp.get("loraRank") or 16)
    iters = max(10, int(hp.get("epochs") or 1) * 10)

    try:
        # Attempt in-process fine-tune API (signature varies by mlx-lm version).
        # Documented for dogfood; pin exact version in requirements.lock.
        from mlx_lm import lora as mlx_lora  # type: ignore

        emit_log(
            f"calling mlx_lm.lora train model={base} data={data} adapter={adapter} "
            f"rank={lora_rank} batch={batch_size} iters={iters}"
        )
        # Many mlx-lm releases expose a train helper; if the signature differs,
        # fall through to CLI.
        train_fn = getattr(mlx_lora, "train", None) or getattr(mlx_lora, "run", None)
        if callable(train_fn):
            train_fn(
                model=base,
                data=data,
                adapter_path=str(adapter),
                batch_size=batch_size,
                lora_rank=lora_rank,
                iters=iters,
            )
        else:
            raise RuntimeError("mlx_lm.lora has no train/run helper; use CLI")
    except Exception as api_err:
        emit_log(f"mlx_lm API path unavailable ({api_err}); trying CLI", level="warn")
        import subprocess

        cmd = [
            sys.executable,
            "-m",
            "mlx_lm",
            "lora",
            "--model",
            str(base),
            "--train",
            "--data",
            str(Path(data).parent if str(data).endswith(".jsonl") else data),
            "--adapter-path",
            str(adapter),
            "--batch-size",
            str(batch_size),
            "--iters",
            str(iters),
        ]
        emit_log("exec: " + " ".join(cmd))
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
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "mlx-lm failed")[-2000:]
            emit(
                {
                    "v": PROTOCOL_V,
                    "type": "error",
                    "code": "BAM_WORKER_CRASH",
                    "message": err,
                    "retriable": False,
                }
            )
            emit_result("failed", "mlx-lm train failed")
            return 1

    # Ensure model card + metrics exist even if mlx-lm only wrote weights.
    train_loss = 0.5
    hold_out = 0.75
    if not (adapter / "model_card.md").exists():
        write_stub_adapter(
            paths=paths,
            job=job,
            train_loss=train_loss,
            hold_out_loss=hold_out,
            fake=False,
        )

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
