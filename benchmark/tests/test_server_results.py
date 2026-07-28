from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from benchmark.sttbench.server import BenchmarkApplication


class ResultQueryTests(unittest.TestCase):
    def test_results_filtering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = BenchmarkApplication(Path(directory))
            app.results_path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "result_id": "r-dup",
                                "recording_id": "recording-001",
                                "backend_id": "backend-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "text": "first attempt",
                                "wall_ms": 120,
                                "audio_seconds": 1.0,
                            }
                        ),
                        json.dumps(
                            {
                                "result_id": "r-b",
                                "recording_id": "recording-001",
                                "backend_id": "backend-b",
                                "backend_name": "Backend B",
                                "family": "remote",
                                "text": "second",
                                "wall_ms": 200,
                                "audio_seconds": 1.0,
                            }
                        ),
                        json.dumps(
                            {
                                "result_id": "r-dup",
                                "recording_id": "recording-001",
                                "backend_id": "backend-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "text": "rerun attempt",
                                "wall_ms": 95,
                                "audio_seconds": 1.0,
                            }
                        ),
                        json.dumps(
                            {
                                "result_id": "r-other",
                                "recording_id": "recording-002",
                                "backend_id": "backend-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "text": "other recording",
                                "wall_ms": 110,
                                "audio_seconds": 1.0,
                            }
                        ),
                    ]
                ),
                encoding="utf-8",
            )

            recording_001 = app.list_results(recording_id="recording-001")
            assert len(recording_001) == 2
            for item in recording_001:
                assert isinstance(item, dict)
            assert recording_001[0]["result_id"] == "r-b"
            assert recording_001[1]["result_id"] == "r-dup"
            assert recording_001[1]["wall_ms"] == 95

            backend_a = app.list_results(recording_id="recording-001", backend_id="backend-a")
            assert len(backend_a) == 1
            assert backend_a[0]["result_id"] == "r-dup"

            all_results = app.list_results()
            assert len(all_results) == 3
            assert all_results[2]["result_id"] == "r-other"

    def test_results_latest_duplicate_wins_without_filtering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = BenchmarkApplication(Path(directory))
            app.results_path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "result_id": "repeat",
                                "recording_id": "recording-001",
                                "backend_id": "backend-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "text": "alpha",
                                "wall_ms": 300,
                                "audio_seconds": 1.0,
                            }
                        ),
                        json.dumps(
                            {
                                "result_id": "repeat",
                                "recording_id": "recording-001",
                                "backend_id": "backend-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "text": "alpha updated",
                                "wall_ms": 140,
                                "audio_seconds": 1.0,
                            }
                        ),
                    ]
                ),
                encoding="utf-8",
            )

            results = app.list_results(recording_id="recording-001")
            assert len(results) == 1
            assert results[0]["result_id"] == "repeat"
            assert results[0]["text"] == "alpha updated"
            assert results[0]["wall_ms"] == 140
