from __future__ import annotations

import csv
import json
import tempfile
import unittest
from pathlib import Path

from benchmark.sttbench.server import BenchmarkApplication


class CorpusEditorTests(unittest.TestCase):
    def test_replace_corpus_from_lines_writes_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_root = root / "data"
            corpus_root.mkdir(parents=True)
            original = {
                "name": "Original corpus",
                "version": 1,
                "description": "fixture",
                "cases": [
                    {"id": f"id-{index:02d}", "category": "Imported", "text": f"line {index}", "keywords": [], "note": ""}
                    for index in range(1, 21)
                ],
            }
            (corpus_root / "personal-20.json").write_text(json.dumps(original, indent=2), encoding="utf-8")

            app = BenchmarkApplication(root)
            payload = "\n".join([f"replacement {index}" for index in range(1, 21)])
            updated = app.replace_corpus(payload)

            assert updated["name"] == "Local dictation gut check"
            assert len(updated["cases"]) == 20
            assert updated["cases"][0]["id"] == "personal-01"
            backups = list(corpus_root.glob("personal-20.json.backup-*"))
            assert len(backups) == 1
            stored = json.loads((corpus_root / "personal-20.json").read_text(encoding="utf-8"))
            assert stored["cases"][1]["text"] == "replacement 2"

    def test_public_corpus_is_used_until_a_private_corpus_exists(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_root = root / "corpus"
            corpus_root.mkdir(parents=True)
            public = {
                "name": "Public corpus",
                "version": 1,
                "description": "fixture",
                "cases": [],
            }
            (corpus_root / "public-20.json").write_text(
                json.dumps(public),
                encoding="utf-8",
            )

            app = BenchmarkApplication(root)

            assert app.corpus()["name"] == "Public corpus"
            assert not app.corpus_path.exists()

    def test_replace_corpus_from_json_cases_array(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = BenchmarkApplication(Path(directory))
            payload = [{"text": f"json case {index}", "keywords": ["bench"], "category": "Custom"} for index in range(1, 21)]
            updated = app.replace_corpus(payload)
            assert len(updated["cases"]) == 20
            assert updated["cases"][10]["text"] == "json case 11"
            assert updated["cases"][0]["keywords"] == ["bench"]


class SummaryExportTests(unittest.TestCase):
    def test_summary_aggregates_deduplicated_results(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = BenchmarkApplication(Path(directory))
            app.results_path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "result_id": "r-001",
                                "recording_id": "r1",
                                "backend_id": "llm-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "warm": False,
                                "wall_ms": 100,
                                "audio_seconds": 1.0,
                                "scores": {
                                    "word_accuracy": 0.8,
                                    "keyword_recall": 0.5,
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "result_id": "r-002",
                                "recording_id": "r1",
                                "backend_id": "llm-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "warm": False,
                                "wall_ms": 120,
                                "audio_seconds": 1.0,
                                "scores": {
                                    "word_accuracy": 0.6,
                                    "keyword_recall": None,
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "result_id": "r-002",
                                "recording_id": "r1",
                                "backend_id": "llm-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "warm": False,
                                "wall_ms": 80,
                                "audio_seconds": 1.0,
                                "scores": {
                                    "word_accuracy": 0.9,
                                    "keyword_recall": 0.8,
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "result_id": "r-003",
                                "recording_id": "r2",
                                "backend_id": "llm-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "warm": True,
                                "wall_ms": 40,
                                "audio_seconds": 1.0,
                                "scores": {
                                    "word_accuracy": 0.5,
                                    "keyword_recall": 0.3,
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "result_id": "r-004",
                                "recording_id": "r2",
                                "backend_id": "llm-b",
                                "backend_name": "Backend B",
                                "family": "remote",
                                "warm": False,
                                "wall_ms": 90,
                                "audio_seconds": 1.0,
                                "error": "decoder fail",
                                "scores": {
                                    "word_accuracy": 0.2,
                                },
                            }
                        ),
                    ]
                ),
                encoding="utf-8",
            )
            app.upsert_rating({"result_id": "r-001", "recording_id": "r1", "backend_id": "llm-a", "rating": "useful"})
            app.upsert_rating({"result_id": "r-003", "recording_id": "r2", "backend_id": "llm-a", "rating": "wrong"})

            payload = app.summary()
            assert payload["counts"]["results"] == 4
            assert payload["counts"]["rated"] == 2
            groups = {(entry["backend_id"], entry["warm"]): entry for entry in payload["summary"]}
            llm_a_cold = groups[("llm-a", False)]
            assert llm_a_cold["count"] == 2
            assert llm_a_cold["error_count"] == 0
            assert llm_a_cold["manual_rating_counts"]["useful"] == 1
            assert llm_a_cold["manual_rating_counts"]["wrong"] == 0

    def test_exports_include_ratings_and_csv(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = BenchmarkApplication(Path(directory))
            app.results_path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "result_id": "x-001",
                                "recording_id": "r1",
                                "backend_id": "llm-a",
                                "backend_name": "Backend A",
                                "family": "local",
                                "repetition": 1,
                                "warm": False,
                                "wall_ms": 110,
                                "backend_ms": 60,
                                "load_ms": 50,
                                "audio_seconds": 1.0,
                                "keywords": ["alpha", "beta"],
                                "scores": {"word_accuracy": 0.7, "wer": 0.3, "keyword_recall": 0.5},
                                "text": "one two",
                                "error": None,
                            }
                        )
                    ]
                ),
                encoding="utf-8",
            )
            app.upsert_rating(
                {
                    "result_id": "x-001",
                    "recording_id": "r1",
                    "backend_id": "llm-a",
                    "rating": "needs_edit",
                    "corrected_text": "one two three",
                }
            )
            content_type, filename, payload = app.export("json")
            assert content_type == "application/json; charset=utf-8"
            assert filename.endswith(".json")
            decoded = json.loads(payload.decode("utf-8"))
            assert decoded["results"][0]["manual_rating"] == "needs_edit"
            assert decoded["ratings"]["x-001"]["rating"] == "needs_edit"

            _, _, csv_bytes = app.export("csv")
            rows = list(csv.reader(csv_bytes.decode("utf-8").splitlines()))
            assert rows[0] == [
                "result_id",
                "recording_id",
                "backend_id",
                "backend_name",
                "family",
                "repetition",
                "reference",
                "text",
                "error",
                "wall_ms",
                "backend_ms",
                "load_ms",
                "audio_seconds",
                "realtime_factor",
                "keywords",
                "warm",
                "phase",
                "wer",
                "word_accuracy",
                "cer",
                "character_accuracy",
                "keyword_recall",
                "exact_normalized",
                "manual_rating",
                "manual_corrected_text",
                "manual_created_at",
                "manual_updated_at",
            ]
            assert rows[1][0] == "x-001"
            assert rows[1][23] == "needs_edit"
