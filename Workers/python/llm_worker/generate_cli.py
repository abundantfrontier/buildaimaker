#!/usr/bin/env python3
"""mlx-lm generate with Gemma 4 unified patches + full-history chat.

mlx-lm 0.31.3 knows `gemma4` but not `gemma4_unified`. Stock `generate` also
only templates `--system-prompt` + one `--prompt`. BAM passes `--messages-json`
(OpenAI-style turns) so Playground follow-ups keep the transcript.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Optional


def apply_gemma4_compat() -> None:
    from mlx_lm import utils as _u

    remap = getattr(_u, "MODEL_REMAPPING", None)
    if isinstance(remap, dict):
        remap.setdefault("gemma4_unified", "gemma4")

    from mlx_lm.models import gemma4 as _g4

    _orig_sanitize = _g4.Model.sanitize

    def _sanitize(self, weights):
        cleaned = {}
        for key, value in weights.items():
            tail = key[6:] if key.startswith("model.") else key
            head = tail.split(".", 1)[0]
            if head.startswith(("vision", "audio", "multi_modal", "multimodal")):
                continue
            cleaned[key] = value
        return _orig_sanitize(self, cleaned)

    _g4.Model.sanitize = _sanitize


def _take_option(argv: list[str], name: str) -> tuple[list[str], Optional[str]]:
    if name not in argv:
        return argv, None
    i = argv.index(name)
    if i + 1 >= len(argv):
        return argv[:i] + argv[i + 1 :], None
    value = argv[i + 1]
    return argv[:i] + argv[i + 2 :], value


def _option_value(argv: list[str], name: str) -> Optional[str]:
    if name not in argv:
        return None
    i = argv.index(name)
    if i + 1 >= len(argv):
        return None
    return argv[i + 1]


def _set_option(argv: list[str], name: str, value: str) -> list[str]:
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv) and not argv[i + 1].startswith("-"):
            argv = argv[: i + 1] + [value] + argv[i + 2 :]
        else:
            argv = argv[: i + 1] + [value] + argv[i + 1 :]
        return argv
    return argv[:1] + [name, value] + argv[1:]


def _drop_flag(argv: list[str], name: str) -> list[str]:
    if name in argv:
        argv = [a for a in argv if a != name]
    return argv


def render_messages_prompt(model_path: str, messages: list[dict[str, Any]]) -> str:
    """Apply the checkpoint's chat template (Gemma maps assistant → model)."""
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(
        model_path,
        trust_remote_code=True,
        local_files_only=True,
    )
    cleaned: list[dict[str, str]] = []
    for row in messages:
        role = str(row.get("role") or "")
        content = str(row.get("content") or "").strip()
        if not content or role not in {"system", "user", "assistant"}:
            continue
        cleaned.append({"role": role, "content": content})
    if not cleaned:
        return ""
    try:
        return tok.apply_chat_template(
            cleaned,
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
    except TypeError:
        return tok.apply_chat_template(
            cleaned,
            tokenize=False,
            add_generation_prompt=True,
        )


def main() -> None:
    apply_gemma4_compat()
    argv = sys.argv[:]
    argv, messages_path = _take_option(argv, "--messages-json")
    if messages_path:
        model_path = _option_value(argv, "--model")
        raw = Path(messages_path).read_text(encoding="utf-8")
        messages = json.loads(raw)
        if not isinstance(messages, list):
            raise SystemExit("--messages-json must be a JSON array of {role, content}")
        if not model_path:
            raise SystemExit("--messages-json requires --model")
        prompt = render_messages_prompt(model_path, messages)
        argv, _ = _take_option(argv, "--system-prompt")
        argv = _set_option(argv, "--prompt", prompt)
        argv = _drop_flag(argv, "--ignore-chat-template")
        argv = argv[:1] + ["--ignore-chat-template"] + argv[1:]
        sys.argv = argv
    else:
        sys.argv = argv
        if "--chat-template-config" not in sys.argv:
            sys.argv[1:1] = ["--chat-template-config", '{"enable_thinking": false}']

    from mlx_lm.generate import main as _main

    _main()


if __name__ == "__main__":
    main()
