"""bam-llm-worker Python entry (spike stub).

Real mlx-lm training is out of scope for PR-PyEnv. This module exists so
runtime-pins.json can hash an entry path and the helper can fail closed on mismatch.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    hello = {
        "v": 1,
        "type": "hello",
        "workerId": "bam-llm-worker",
        "workerVersion": "0.1.0",
        "caps": {
            "modalities": ["llm"],
            "resume": True,
            "modelFamilies": ["qwen2.5"],
            "maxSeqLen": 8192,
        },
    }
    sys.stdout.write(json.dumps(hello, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
