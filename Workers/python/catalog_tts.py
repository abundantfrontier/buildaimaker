#!/usr/bin/env python3
"""Kokoro catalog TTS for BuildAIMaker character voices.

Distinct built-in speakers (not clone). Logs go to stderr; stdout is JSON only
so a Swift sidecar can keep a warm process.

Commands:
  status   — print readiness JSON
  speak    — one-shot WAV
  serve    — JSONL stdin/stdout server (keeps the ONNX session warm)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from pathlib import Path
from typing import Any, Optional

MODEL_NAME = "kokoro-v1.0.onnx"
VOICES_NAME = "voices-v1.0.bin"
MODEL_URL = (
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/"
    "model-files-v1.0/kokoro-v1.0.onnx"
)
VOICES_URL = (
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/"
    "model-files-v1.0/voices-v1.0.bin"
)


def _log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def default_model_dir() -> Path:
    override = os.environ.get("BAM_KOKORO_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "BuildAIMaker"
        / "models"
        / "tts"
        / "kokoro"
    )


def model_paths(model_dir: Optional[Path] = None) -> tuple[Path, Path]:
    root = model_dir or default_model_dir()
    return root / MODEL_NAME, root / VOICES_NAME


def is_ready(model_dir: Optional[Path] = None) -> bool:
    model, voices = model_paths(model_dir)
    try:
        import kokoro_onnx  # noqa: F401
        import soundfile  # noqa: F401
    except Exception:
        return False
    return model.is_file() and voices.is_file() and model.stat().st_size > 1_000_000


def status_payload(model_dir: Optional[Path] = None) -> dict[str, Any]:
    model, voices = model_paths(model_dir)
    try:
        import kokoro_onnx

        version = getattr(kokoro_onnx, "__version__", None) or "ok"
        imported = True
    except Exception as exc:
        version = None
        imported = False
        import_error = str(exc)
    else:
        import_error = None
    return {
        "ok": True,
        "ready": is_ready(model_dir),
        "engineId": "kokoro-catalog-v1",
        "imported": imported,
        "kokoroVersion": version,
        "importError": import_error,
        "modelPath": str(model),
        "voicesPath": str(voices),
        "modelPresent": model.is_file(),
        "voicesPresent": voices.is_file(),
    }


_kokoro = None
_g2p_us = None
_g2p_gb = None


def _load(model_dir: Optional[Path] = None):
    global _kokoro
    if _kokoro is not None:
        return _kokoro
    os.environ.setdefault("ORT_LOG_SEVERITY_LEVEL", "3")
    from kokoro_onnx import Kokoro

    model, voices = model_paths(model_dir)
    if not model.is_file() or not voices.is_file():
        raise FileNotFoundError(f"Kokoro model files missing under {model.parent}")
    _log(f"loading Kokoro {model.name}")
    _kokoro = Kokoro(str(model), str(voices))
    return _kokoro


def _phonemes(text: str, lang: str) -> Optional[str]:
    global _g2p_us, _g2p_gb
    try:
        from misaki import en
    except Exception:
        return None
    british = lang.lower() in {"en-gb", "en_gb", "b"}
    if british:
        if _g2p_gb is None:
            _g2p_gb = en.G2P(trf=False, british=True)
        g2p = _g2p_gb
    else:
        if _g2p_us is None:
            _g2p_us = en.G2P(trf=False, british=False)
        g2p = _g2p_us
    phonemes, _ = g2p(text)
    return phonemes or None


def synthesize(
    text: str,
    voice: str,
    speed: float = 1.0,
    lang: str = "en-us",
    model_dir: Optional[Path] = None,
):
    trimmed = (text or "").strip()
    if not trimmed:
        raise ValueError("empty text")
    kokoro = _load(model_dir)
    speed = max(0.6, min(1.4, float(speed)))
    phonemes = _phonemes(trimmed, lang)
    if phonemes:
        samples, sample_rate = kokoro.create(
            phonemes, voice=voice, speed=speed, is_phonemes=True
        )
    else:
        samples, sample_rate = kokoro.create(
            trimmed, voice=voice, speed=speed, lang=lang
        )
    return samples, int(sample_rate)


def write_wav(path: Path, samples, sample_rate: int) -> None:
    import soundfile as sf

    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), samples, sample_rate)


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def cmd_status(args: argparse.Namespace) -> int:
    emit(status_payload(Path(args.model_dir) if args.model_dir else None))
    return 0


def cmd_speak(args: argparse.Namespace) -> int:
    model_dir = Path(args.model_dir) if args.model_dir else None
    out = Path(args.out)
    try:
        samples, rate = synthesize(
            args.text,
            voice=args.voice,
            speed=args.speed,
            lang=args.lang,
            model_dir=model_dir,
        )
        write_wav(out, samples, rate)
    except Exception as exc:
        emit({"ok": False, "error": str(exc)})
        return 1
    emit(
        {
            "ok": True,
            "path": str(out.resolve()),
            "sampleRate": rate,
            "voice": args.voice,
            "engineId": "kokoro-catalog-v1",
        }
    )
    return 0


def cmd_serve(args: argparse.Namespace) -> int:
    model_dir = Path(args.model_dir) if args.model_dir else None
    # Load on boot so the first Hear is not a 5s stall after "ready".
    try:
        _load(model_dir)
        emit({"ok": True, "ready": True, "engineId": "kokoro-catalog-v1"})
    except Exception as exc:
        emit({"ok": False, "ready": False, "error": str(exc)})
        return 1

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            emit({"ok": False, "error": f"bad json: {exc}"})
            continue
        cmd = (req.get("cmd") or "speak").strip().lower()
        if cmd in {"quit", "exit"}:
            emit({"ok": True, "bye": True})
            return 0
        if cmd == "ping":
            emit({"ok": True, "ready": True})
            continue
        if cmd != "speak":
            emit({"ok": False, "error": f"unknown cmd {cmd}"})
            continue
        try:
            text = str(req.get("text") or "")
            voice = str(req.get("voice") or "af_heart")
            speed = float(req.get("speed") or 1.0)
            lang = str(req.get("lang") or "en-us")
            out = Path(str(req.get("out") or ""))
            if not out.parts:
                raise ValueError("missing out")
            samples, rate = synthesize(
                text, voice=voice, speed=speed, lang=lang, model_dir=model_dir
            )
            write_wav(out, samples, rate)
            emit(
                {
                    "ok": True,
                    "path": str(out.resolve()),
                    "sampleRate": rate,
                    "voice": voice,
                    "engineId": "kokoro-catalog-v1",
                }
            )
        except Exception as exc:
            _log(traceback.format_exc())
            emit({"ok": False, "error": str(exc)})
    return 0


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="catalog_tts")
    sub = p.add_subparsers(dest="command", required=True)

    def add_model_dir(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--model-dir", default=None)

    st = sub.add_parser("status")
    add_model_dir(st)

    speak = sub.add_parser("speak")
    add_model_dir(speak)
    speak.add_argument("--text", required=True)
    speak.add_argument("--voice", default="af_heart")
    speak.add_argument("--speed", type=float, default=1.0)
    speak.add_argument("--lang", default="en-us")
    speak.add_argument("--out", required=True)

    serve = sub.add_parser("serve")
    add_model_dir(serve)
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "status":
        return cmd_status(args)
    if args.command == "speak":
        return cmd_speak(args)
    if args.command == "serve":
        return cmd_serve(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
