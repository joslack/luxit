#!/usr/bin/env python3
"""Export privacy-safe aggregate benchmark results.

The private JSONL input includes recordings, transcripts, references, local
paths, timestamps, and identifiers. This exporter deliberately emits only
cohort-level and backend-level aggregate statistics.
"""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path
from typing import Any


BACKENDS: dict[str, dict[str, Any]] = {
    "transducer-libparakeet-v3-q8-0-metal": {
        "name": "Parakeet TDT 0.6B v3 Q8_0 (Metal)",
        "family": "transducer",
        "runtime": "libparakeet",
        "execution": "Metal",
        "available_in_luxit": True,
    },
    "transducer-libparakeet-cli-v3-q8-0": {
        "name": "Parakeet TDT 0.6B v3 Q8_0 (CPU)",
        "family": "transducer",
        "runtime": "libparakeet",
        "execution": "CPU, 4 threads",
        "available_in_luxit": True,
    },
    "mlx-whisper-turbo-4bit": {
        "name": "Whisper large-v3-turbo 4-bit",
        "family": "whisper",
        "runtime": "mlx-audio",
        "execution": "MLX",
        "available_in_luxit": False,
    },
    "whisper-cpp-fast-greedy-v3-turbo-q5_0": {
        "name": "Whisper large-v3-turbo Q5_0 (greedy)",
        "family": "whisper",
        "runtime": "whisper.cpp",
        "execution": "Metal + Accelerate",
        "available_in_luxit": True,
    },
    "whisper-cpp-baseline-v3-turbo-q5_0": {
        "name": "Whisper large-v3-turbo Q5_0 (baseline)",
        "family": "whisper",
        "runtime": "whisper.cpp",
        "execution": "Metal + Accelerate",
        "available_in_luxit": False,
    },
    "whisperkit-large-v3-turbo": {
        "name": "WhisperKit large-v3-turbo",
        "family": "whisper",
        "runtime": "WhisperKit",
        "execution": "Core ML",
        "available_in_luxit": False,
    },
    "whisperkit-distil-large-v3": {
        "name": "WhisperKit distil-large-v3",
        "family": "whisper",
        "runtime": "WhisperKit",
        "execution": "Core ML",
        "available_in_luxit": False,
    },
}


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("percentile requires at least one value")
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(len(ordered) - 1, lower + 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def rounded(value: float, places: int = 4) -> float:
    return round(float(value), places)


def mean_score(rows: list[dict[str, Any]], key: str) -> float | None:
    values = [
        float(row["scores"][key])
        for row in rows
        if isinstance(row.get("scores"), dict)
        and isinstance(row["scores"].get(key), (int, float))
    ]
    return statistics.fmean(values) if values else None


def read_canonical_rows(path: Path) -> list[dict[str, Any]]:
    latest: dict[tuple[str, str, int], dict[str, Any]] = {}
    with path.open(encoding="utf-8") as source:
        for line in source:
            row = json.loads(line)
            backend_id = row.get("backend_id")
            if backend_id not in BACKENDS or row.get("error") is not None:
                continue
            key = (
                backend_id,
                str(row.get("recording_id")),
                int(row.get("repetition", 0)),
            )
            previous = latest.get(key)
            if previous is None or str(row.get("created_at", "")) >= str(
                previous.get("created_at", "")
            ):
                latest[key] = row
    rows = list(latest.values())
    if len(rows) != 560:
        raise ValueError(f"expected 560 canonical measurements, found {len(rows)}")
    return rows


def build_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    recording_ids = {str(row["recording_id"]) for row in rows}
    if len(recording_ids) != 20:
        raise ValueError(f"expected 20 recordings, found {len(recording_ids)}")

    duration_by_recording: dict[str, float] = {}
    for row in rows:
        duration_by_recording.setdefault(
            str(row["recording_id"]),
            float(row["audio_seconds"]),
        )

    aggregates: list[dict[str, Any]] = []
    for backend_id, metadata in BACKENDS.items():
        backend_rows = [row for row in rows if row["backend_id"] == backend_id]
        cold = [row for row in backend_rows if not row["warm"]]
        warm = [row for row in backend_rows if row["warm"]]
        if len(cold) != 20 or len(warm) != 60:
            raise ValueError(
                f"{backend_id}: expected 20 cold and 60 warm rows; "
                f"found {len(cold)} and {len(warm)}"
            )

        warm_ms = [float(row["wall_ms"]) for row in warm]
        cold_ms = [float(row["wall_ms"]) for row in cold]
        realtime = [float(row["realtime_factor"]) for row in warm]
        wer = mean_score(backend_rows, "wer")
        cer = mean_score(backend_rows, "cer")
        keyword_recall = mean_score(backend_rows, "keyword_recall")
        exact = mean_score(backend_rows, "exact_normalized")
        if wer is None or cer is None or keyword_recall is None or exact is None:
            raise ValueError(f"{backend_id}: missing required aggregate score")

        aggregates.append(
            {
                "backend_id": backend_id,
                **metadata,
                "measurements": {
                    "cold": len(cold),
                    "warm": len(warm),
                },
                "latency_ms": {
                    "cold_p50": rounded(statistics.median(cold_ms), 1),
                    "warm_p50": rounded(statistics.median(warm_ms), 1),
                    "warm_mean": rounded(statistics.fmean(warm_ms), 1),
                    "warm_p90": rounded(percentile(warm_ms, 0.90), 1),
                },
                "warm_realtime_multiple_p50": rounded(
                    statistics.median(realtime),
                    1,
                ),
                "accuracy": {
                    "macro_wer": rounded(wer),
                    "macro_cer": rounded(cer),
                    "keyword_recall": rounded(keyword_recall),
                    "exact_normalized_rate": rounded(exact),
                },
            }
        )

    aggregates.sort(
        key=lambda backend: (
            backend["accuracy"]["macro_wer"],
            backend["latency_ms"]["warm_p50"],
        )
    )
    for rank, backend in enumerate(aggregates, start=1):
        backend["accuracy_rank"] = rank

    latency_order = sorted(
        aggregates,
        key=lambda backend: backend["latency_ms"]["warm_p50"],
    )
    for rank, backend in enumerate(latency_order, start=1):
        backend["warm_latency_rank"] = rank

    pareto_ids: list[str] = []
    for candidate in aggregates:
        candidate_wer = candidate["accuracy"]["macro_wer"]
        candidate_latency = candidate["latency_ms"]["warm_p50"]
        dominated = any(
            other["backend_id"] != candidate["backend_id"]
            and other["accuracy"]["macro_wer"] <= candidate_wer
            and other["latency_ms"]["warm_p50"] <= candidate_latency
            and (
                other["accuracy"]["macro_wer"] < candidate_wer
                or other["latency_ms"]["warm_p50"] < candidate_latency
            )
            for other in aggregates
        )
        if not dominated:
            pareto_ids.append(candidate["backend_id"])

    return {
        "schema_version": 1,
        "generated_on": "2026-07-28",
        "hardware": {
            "model": "MacBook Pro",
            "chip": "Apple M3 Pro",
            "cpu_cores": 11,
            "memory_gb": 18,
            "architecture": "arm64",
            "macos_version": "26.5.1",
        },
        "cohort": {
            "language": "English",
            "private_utterances": 20,
            "runs_per_backend": 4,
            "cold_runs_per_backend": 20,
            "warm_runs_per_backend": 60,
            "unique_audio_seconds": rounded(
                sum(duration_by_recording.values()),
                1,
            ),
            "comparison_note": (
                "Every backend used the same private recordings and references. "
                "This is a product-choice comparison, not an "
                "architecture-controlled study."
            ),
        },
        "selection": {
            "best_pareto": "transducer-libparakeet-v3-q8-0-metal",
            "fastest_warm": "transducer-libparakeet-v3-q8-0-metal",
            "most_accurate": [
                "transducer-libparakeet-v3-q8-0-metal",
                "transducer-libparakeet-cli-v3-q8-0",
            ],
            "luxit_menu": [
                "transducer-libparakeet-v3-q8-0-metal",
                "transducer-libparakeet-cli-v3-q8-0",
                "whisper-cpp-fast-greedy-v3-turbo-q5_0",
            ],
            "rationale": (
                "Parakeet Metal dominates the completed cohort on accuracy and "
                "latency. CPU Parakeet preserves its transcript quality as a "
                "fallback. whisper.cpp greedy is the strongest wired "
                "alternative architecture."
            ),
        },
        "pareto_frontier": pareto_ids,
        "backends": sorted(
            aggregates,
            key=lambda backend: backend["warm_latency_rank"],
        ),
        "privacy": {
            "contains_audio": False,
            "contains_transcripts": False,
            "contains_references": False,
            "contains_keywords": False,
            "contains_recording_or_result_ids": False,
            "contains_timestamps": False,
            "contains_local_paths_or_service_urls": False,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    benchmark_root = Path(__file__).resolve().parents[1]
    parser.add_argument(
        "--input",
        type=Path,
        default=benchmark_root / "data" / "results.jsonl",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=benchmark_root / "results" / "m3-pro-local-voice-aggregate.json",
    )
    args = parser.parse_args()

    summary = build_summary(read_canonical_rows(args.input))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(summary, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
