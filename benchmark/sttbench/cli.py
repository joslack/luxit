from __future__ import annotations

import argparse
import json
from pathlib import Path

from .registry import BackendRegistry
from .runner import BenchmarkRunner


def main() -> None:
    parser = argparse.ArgumentParser(description="Inspect and run local STT backends")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Benchmark project root",
    )
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("list", help="List configured backends and availability")

    run = subcommands.add_parser("run", help="Run one WAV through selected backends")
    run.add_argument("--audio", required=True)
    run.add_argument("--reference", required=True)
    run.add_argument("--keywords", nargs="*", default=[])
    run.add_argument("--backend", action="append", dest="backends", required=True)
    run.add_argument("--language", default="en")
    run.add_argument("--prompt")
    run.add_argument("--warmups", type=int, default=1)
    run.add_argument("--repetitions", type=int, default=1)

    args = parser.parse_args()
    if args.command == "list":
        registry = BackendRegistry(args.root)
        for backend in registry.public_specs():
            state = "ready" if backend["available"] else "unavailable"
            print(f"{backend['id']}\t{state}\t{backend['name']}")
            for reason in backend["unavailable_reasons"]:
                print(f"  - {reason}")
        return

    runner = BenchmarkRunner(args.root)
    try:
        results = runner.run(
            recording_id=Path(args.audio).stem,
            audio_path=str(Path(args.audio).resolve()),
            backend_ids=args.backends,
            reference=args.reference,
            keywords=args.keywords,
            language=args.language,
            prompt=args.prompt,
            warmups=args.warmups,
            repetitions=args.repetitions,
        )
        print(json.dumps(results, indent=2))
    finally:
        runner.close()


if __name__ == "__main__":
    main()
