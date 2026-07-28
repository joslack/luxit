#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from sttbench.registry import BackendRegistry


def main() -> int:
    parser = argparse.ArgumentParser(
        description="List whisper-family backend manifests and availability."
    )
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Path to benchmark root.",
    )
    args = parser.parse_args()

    registry = BackendRegistry(Path(args.root))
    whisper_specs = [
        spec
        for spec in registry.public_specs()
        if str(spec["family"]).lower() == "whisper"
    ]
    print(json.dumps(whisper_specs, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
