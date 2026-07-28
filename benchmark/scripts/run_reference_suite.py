#!/usr/bin/env python3
"""Run the five prepared ground-truth clips through selected ready backends."""

from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

from sttbench.runner import BenchmarkRunner


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", action="append", dest="backends")
    parser.add_argument("--warmups", type=int, default=0)
    parser.add_argument("--repetitions", type=int, default=1)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    corpus_path = root / "data" / "reference" / "corpus.json"
    if not corpus_path.exists():
        raise SystemExit(
            "Reference corpus is missing. Run benchmark/scripts/fetch_reference_corpus.py."
        )

    runner = BenchmarkRunner(root)
    public = runner.registry.public_specs()
    ready_ids = [item["id"] for item in public if item["available"]]
    backend_ids = args.backends or ready_ids
    unavailable = sorted(set(backend_ids) - set(ready_ids))
    if unavailable:
        raise SystemExit(f"Backends are unavailable: {', '.join(unavailable)}")

    corpus = json.loads(corpus_path.read_text())
    all_results: list[dict] = []
    try:
        for case in corpus["cases"]:
            print(f"{case['id']}: {len(backend_ids)} backends", flush=True)
            all_results.extend(
                runner.run(
                    recording_id=f"reference-{case['id']}",
                    audio_path=case["audio_path"],
                    backend_ids=backend_ids,
                    reference=case["text"],
                    keywords=[],
                    language="en",
                    prompt=None,
                    warmups=args.warmups,
                    repetitions=args.repetitions,
                )
            )
    finally:
        runner.close()

    grouped: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for item in all_results:
        grouped[(item["backend_id"], "warm" if item["warm"] else "cold")].append(item)

    print("\nbackend\tphase\tclips\taccuracy\tlatency_ms\trealtime_x\terrors")
    for (backend_id, phase), values in sorted(grouped.items()):
        successful = [item for item in values if not item.get("error") and item.get("scores")]
        accuracy = statistics.fmean(
            item["scores"]["word_accuracy"] for item in successful
        ) if successful else 0.0
        latency = statistics.fmean(item["wall_ms"] for item in successful) if successful else 0.0
        speed = statistics.fmean(
            item["realtime_factor"] for item in successful if item.get("realtime_factor")
        ) if successful else 0.0
        errors = len(values) - len(successful)
        print(
            f"{backend_id}\t{phase}\t{len(values)}\t{accuracy:.3f}\t"
            f"{latency:.1f}\t{speed:.2f}\t{errors}"
        )


if __name__ == "__main__":
    main()
