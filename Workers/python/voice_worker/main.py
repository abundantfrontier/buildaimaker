"""bam-voice-worker Python entry (PR-VoiceSpike stub).

Real F5-TTS clone is out of scope for CI — no multi-GB wheel/model download.
This module:

1. Emits a protocol-compatible ``hello`` when run with no args (helper L2 entry).
2. Provides a CLI that accepts a reference WAV and writes a **stub**
   ``voice_profile`` directory (profile.json + copied reference.wav + empty cache).

See Docs/adr/0002-voice-engine.md for engine pin, SPDX, and install size budget.

Exit codes (CLI only — not supervised NDJSON train path):
  0  success / hello
  1  handled failure (e.g. missing ref wav)
  2  reserved (protocol/usage; matches WorkerExitCode.protocolError)
  3  spike-CLI-only BAM_LICENSE_BLOCK (XTTS etc.); **not** a WorkerExitCode.
     Supervised workers must emit protocol error with code BAM_LICENSE_BLOCK and
     exit 1 (handledFailure) — never exit 3 under ProcessSupervisor.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Optional


WORKER_ID = "bam-voice-worker"
WORKER_VERSION = "0.1.0"
DEFAULT_ENGINE_ID = "f5-tts"
PROFILE_SCHEMA_VERSION = 1

# AGPL / non-default engines — must never write a profile with these ids.
# Shared by library API and CLI (defense in depth; not CLI-only).
BLOCKED_ENGINE_IDS = frozenset({"xtts", "xtts-v2", "coqui-xtts"})

# Spike CLI-only exit for BAM_LICENSE_BLOCK. Not in WorkerExitCode; see module docstring.
CLI_EXIT_LICENSE_BLOCK = 3


class LicenseBlockError(ValueError):
    """Raised when engine_id is non-default / license-blocked (e.g. XTTS AGPL)."""

    def __init__(self, engine_id: str, message: Optional[str] = None) -> None:
        self.engine_id = engine_id
        self.code = "BAM_LICENSE_BLOCK"
        super().__init__(
            message
            or (
                f"BAM_LICENSE_BLOCK: engine {engine_id!r} is AGPL / non-default; "
                f"use engine-id {DEFAULT_ENGINE_ID} (see Docs/adr/0002-voice-engine.md)"
            )
        )


def is_blocked_engine(engine_id: str) -> bool:
    """True when ``engine_id`` is on the non-default / AGPL denylist (case-insensitive)."""
    return (engine_id or "").strip().lower() in BLOCKED_ENGINE_IDS


def assert_engine_allowed(engine_id: str) -> None:
    """Raise ``LicenseBlockError`` if engine is blocked (XTTS family, etc.)."""
    if is_blocked_engine(engine_id):
        raise LicenseBlockError(engine_id)


def _iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def hello_payload() -> dict[str, Any]:
    return {
        "v": 1,
        "type": "hello",
        "workerId": WORKER_ID,
        "workerVersion": WORKER_VERSION,
        "caps": {
            "modalities": ["voiceClone"],
            "resume": False,
            "modelFamilies": ["f5-tts"],
            "engineIds": [DEFAULT_ENGINE_ID],
        },
    }


def emit_hello() -> int:
    sys.stdout.write(json.dumps(hello_payload(), separators=(",", ":")) + "\n")
    sys.stdout.flush()
    return 0


def build_profile(
    *,
    engine_id: str,
    consent_record_id: Optional[str],
    consent_content_hash: Optional[str],
    language: str,
    sample_text: Optional[str],
    reference_audio_hash: str,
    stub: bool,
) -> dict[str, Any]:
    assert_engine_allowed(engine_id)
    profile: dict[str, Any] = {
        "v": PROFILE_SCHEMA_VERSION,
        "kind": "voice_profile",
        "engineId": engine_id,
        "language": language,
        "referenceAudioHash": f"sha256:{reference_audio_hash}",
        "createdAt": _iso_now(),
        "stub": stub,
    }
    if consent_record_id:
        profile["consentRecordId"] = consent_record_id
    if consent_content_hash:
        profile["consentContentHash"] = consent_content_hash
    if sample_text:
        profile["sampleText"] = sample_text
    if stub:
        profile["note"] = (
            "Stub profile from PR-VoiceSpike CLI; no F5-TTS model was loaded or downloaded."
        )
    return profile


def write_stub_voice_profile(
    *,
    ref_wav: Path,
    out_dir: Path,
    engine_id: str = DEFAULT_ENGINE_ID,
    consent_record_id: Optional[str] = None,
    consent_content_hash: Optional[str] = None,
    language: str = "en",
    sample_text: Optional[str] = None,
) -> Mapping[str, Any]:
    """Copy ref wav + write profile.json under out_dir. No model download.

    Layout (design doc voice_profile artifact):
      out_dir/
        profile.json
        reference.wav
        engine_cache/   (empty placeholder for engine-specific cache)

    Raises:
      LicenseBlockError: blocked engine id (XTTS family) — before any write.
      FileNotFoundError: reference wav missing.
    """
    # Gate before any mkdir/copy so library callers share the CLI policy.
    assert_engine_allowed(engine_id)

    if not ref_wav.is_file():
        raise FileNotFoundError(f"reference wav not found: {ref_wav}")

    out_dir.mkdir(parents=True, exist_ok=True)
    cache_dir = out_dir / "engine_cache"
    cache_dir.mkdir(parents=True, exist_ok=True)

    dest_wav = out_dir / "reference.wav"
    shutil.copy2(ref_wav, dest_wav)
    ref_hash = _sha256_file(dest_wav)

    profile = build_profile(
        engine_id=engine_id,
        consent_record_id=consent_record_id,
        consent_content_hash=consent_content_hash,
        language=language,
        sample_text=sample_text,
        reference_audio_hash=ref_hash,
        stub=True,
    )
    profile_path = out_dir / "profile.json"
    profile_path.write_text(
        json.dumps(profile, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    return {
        "voiceProfileDir": str(out_dir.resolve()),
        "profilePath": str(profile_path.resolve()),
        "referenceWavPath": str(dest_wav.resolve()),
        "referenceAudioHash": f"sha256:{ref_hash}",
        "engineId": engine_id,
        "stub": True,
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="voice_worker",
        description=(
            "BuildAIMaker voice worker (spike). "
            "Default: emit protocol hello. "
            "Subcommand 'clone': write stub voice_profile from a reference WAV "
            "(no multi-GB download)."
        ),
    )
    sub = parser.add_subparsers(dest="command")

    clone = sub.add_parser(
        "clone",
        help="Write stub voice_profile dir from reference WAV (CI-safe; no model download).",
    )
    clone.add_argument(
        "--ref-wav",
        required=True,
        type=Path,
        help="Path to reference speech WAV (design: ~15 s clean speech).",
    )
    clone.add_argument(
        "--out-dir",
        required=True,
        type=Path,
        help="Output voice_profile directory (created if missing).",
    )
    clone.add_argument(
        "--engine-id",
        default=DEFAULT_ENGINE_ID,
        help=f"Engine id (default: {DEFAULT_ENGINE_ID}). XTTS is non-default / not offered here.",
    )
    clone.add_argument("--consent-record-id", default=None)
    clone.add_argument("--consent-content-hash", default=None)
    clone.add_argument("--language", default="en")
    clone.add_argument(
        "--sample-text",
        default="Hello, this is a preview of my voice.",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        return emit_hello()

    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "clone":
        try:
            result = write_stub_voice_profile(
                ref_wav=args.ref_wav,
                out_dir=args.out_dir,
                engine_id=args.engine_id,
                consent_record_id=args.consent_record_id,
                consent_content_hash=args.consent_content_hash,
                language=args.language,
                sample_text=args.sample_text,
            )
        except LicenseBlockError as exc:
            sys.stderr.write(f"{exc}\n")
            return CLI_EXIT_LICENSE_BLOCK
        except FileNotFoundError as exc:
            sys.stderr.write(f"error: {exc}\n")
            return 1
        sys.stdout.write(json.dumps(result, separators=(",", ":"), sort_keys=True) + "\n")
        sys.stdout.flush()
        return 0

    # Unknown / bare invocation after parse — treat as hello for helper path.
    return emit_hello()


if __name__ == "__main__":
    raise SystemExit(main())
