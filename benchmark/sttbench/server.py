from __future__ import annotations

import argparse
import csv
import json
from collections import defaultdict
from collections.abc import Iterable
from datetime import datetime, timezone
from io import StringIO
from uuid import uuid4
from statistics import mean
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from typing import Any
from urllib.parse import parse_qs, urlparse

from .runner import BenchmarkRunner

VALID_RATINGS = {"useful", "needs_edit", "wrong"}


@dataclass
class Job:
    id: str
    status: str = "queued"
    created_at: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    results: list[dict[str, Any]] = field(default_factory=list)
    error: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "status": self.status,
            "created_at": self.created_at,
            "results": self.results,
            "error": self.error,
        }


class BenchmarkApplication:
    CORPUS_NAME = "Local dictation gut check"

    def __init__(self, root: Path):
        self.root = root
        self.runner = BenchmarkRunner(root)
        self.results_path = self.runner.results_path
        self.recordings_dir = root / "data" / "recordings"
        self.recordings_dir.mkdir(parents=True, exist_ok=True)
        self.public_corpus_path = root / "corpus" / "public-20.json"
        self.corpus_path = root / "data" / "personal-20.json"
        self.ratings_path = root / "data" / "ratings.jsonl"
        self.jobs: dict[str, Job] = {}
        self.jobs_lock = Lock()
        self.ratings_lock = Lock()
        self.summary_lock = Lock()
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="sttbench")

    def corpus(self) -> dict[str, Any]:
        source_path = (
            self.corpus_path
            if self.corpus_path.exists()
            else self.public_corpus_path
        )
        with source_path.open() as source:
            return json.load(source)

    def recordings(self) -> list[dict[str, Any]]:
        result = []
        for metadata_path in sorted(
            self.recordings_dir.glob("*.json"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        ):
            with metadata_path.open() as source:
                result.append(json.load(source))
        return result

    def _read_jsonl(self, path: Path) -> list[dict[str, Any]]:
        if not path.exists():
            return []
        records: list[dict[str, Any]] = []
        with path.open() as source:
            for line in source:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(payload, dict):
                    records.append(payload)
        return records

    @staticmethod
    def _mean(values: Iterable[Any]) -> float | None:
        numeric = [float(value) for value in values if isinstance(value, (int, float))]
        if not numeric:
            return None
        return mean(numeric)

    @staticmethod
    def _flatten_value(value: Any) -> str | float | int | bool:
        if value is None:
            return ""
        if isinstance(value, (list, tuple)):
            return " | ".join(str(item) for item in value)
        if isinstance(value, dict):
            return json.dumps(value, separators=(",", ":"))
        return value

    def _coerce_case_id(self, candidate: Any, used: set[str], index: int) -> str:
        base = (
            str(candidate).strip()
            if isinstance(candidate, str) and str(candidate).strip()
            else f"personal-{index + 1:02d}"
        )
        if base not in used:
            return base
        suffix = 2
        next_id = f"{base}-{suffix:02d}"
        while next_id in used:
            suffix += 1
            next_id = f"{base}-{suffix:02d}"
        return next_id

    def _normalize_cases(self, case_inputs: list[Any], source_is_text: bool = False) -> list[dict[str, Any]]:
        if len(case_inputs) != 20:
            raise ValueError("corpus must contain exactly 20 cases")
        normalized: list[dict[str, Any]] = []
        used_ids: set[str] = set()

        for index, item in enumerate(case_inputs):
            if source_is_text:
                text = item.strip()
                if not text:
                    raise ValueError("case text must not be empty")
                entry: dict[str, Any] = {
                    "id": f"personal-{index + 1:02d}",
                    "category": "Imported",
                    "text": text,
                    "keywords": [],
                    "note": "Imported line-based corpus",
                }
            elif isinstance(item, str):
                text = item.strip()
                if not text:
                    raise ValueError("case text must not be empty")
                entry = {
                    "id": f"personal-{index + 1:02d}",
                    "category": "Imported",
                    "text": text,
                    "keywords": [],
                    "note": "Imported list of phrases",
                }
            elif isinstance(item, dict):
                text = item.get("text")
                if not isinstance(text, str) or not text.strip():
                    raise ValueError("case text must be a non-empty string")
                keywords = item.get("keywords", [])
                if not isinstance(keywords, list):
                    raise ValueError("keywords must be an array of strings")
                if any(not isinstance(keyword, str) for keyword in keywords):
                    raise ValueError("keywords must be an array of strings")
                case_id = self._coerce_case_id(item.get("id"), used_ids, index)
                category = item.get("category", "Imported")
                if not isinstance(category, str) or not category.strip():
                    category = "Imported"
                note = item.get("note", "")
                if not isinstance(note, str):
                    raise ValueError("note must be a string")
                entry = {
                    "id": case_id,
                    "category": category,
                    "text": text,
                    "keywords": [keyword.strip() for keyword in keywords if keyword.strip()],
                    "note": note,
                }
            else:
                raise ValueError("cases must be strings or objects")

            used_ids.add(entry["id"])
            normalized.append(entry)
        return normalized

    def _coerce_import_cases(self, payload: Any) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        metadata = {
            "name": self.CORPUS_NAME,
            "version": 1,
            "description": "Personal benchmark corpus",
        }
        if isinstance(payload, str):
            lines = [line.strip() for line in payload.splitlines() if line.strip()]
            return metadata, self._normalize_cases(lines, source_is_text=True)
        if isinstance(payload, dict) and "cases" in payload:
            metadata["name"] = payload.get("name", metadata["name"])
            metadata["version"] = payload.get("version", metadata["version"])
            metadata["description"] = payload.get("description", metadata["description"])
            payload = payload["cases"]
        if not isinstance(payload, list):
            raise ValueError(
                "corpus payload must be a JSON cases array, a corpus object with cases, or plain text lines"
            )
        return metadata, self._normalize_cases(payload)

    def _backup_corpus(self) -> None:
        if self.corpus_path.exists():
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            backup = self.corpus_path.with_name(
                f"{self.corpus_path.name}.backup-{timestamp}.json"
            )
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_text(self.corpus_path.read_text(encoding="utf-8"), encoding="utf-8")

    def replace_corpus(self, payload: Any) -> dict[str, Any]:
        metadata, cases = self._coerce_import_cases(payload)
        corpus = {
            "name": metadata["name"],
            "version": metadata["version"],
            "description": metadata["description"],
            "cases": cases,
        }
        self._backup_corpus()
        self.corpus_path.parent.mkdir(parents=True, exist_ok=True)
        self.corpus_path.write_text(json.dumps(corpus, indent=2) + "\n", encoding="utf-8")
        return corpus

    def list_ratings(self) -> dict[str, dict[str, Any]]:
        with self.ratings_lock:
            result = {}
            for item in self._read_jsonl(self.ratings_path):
                result_id = item.get("result_id")
                if isinstance(result_id, str):
                    result[result_id] = item
            return result

    def upsert_rating(self, payload: dict[str, Any]) -> dict[str, Any]:
        result_id = payload.get("result_id")
        if not isinstance(result_id, str) or not result_id.strip():
            raise ValueError("Missing result_id")
        rating = payload.get("rating")
        if rating not in VALID_RATINGS:
            raise ValueError("rating must be one of: useful, needs_edit, wrong")
        corrected_text = payload.get("corrected_text")
        if corrected_text is not None and not isinstance(corrected_text, str):
            raise ValueError("corrected_text must be a string")
        existing = self.list_ratings().get(result_id, {})
        now = datetime.now(timezone.utc).isoformat()
        entry = {
            "result_id": result_id,
            "recording_id": payload.get("recording_id", ""),
            "backend_id": payload.get("backend_id", ""),
            "rating": rating,
            "corrected_text": corrected_text,
            "created_at": existing.get("created_at", now),
            "updated_at": now,
        }
        with self.ratings_lock:
            with self.ratings_path.open("a") as target:
                target.write(json.dumps(entry, separators=(",", ":")) + "\n")
        return entry

    def list_results(self, recording_id: str | None = None, backend_id: str | None = None) -> list[dict[str, Any]]:
        return self._results(recording_id=recording_id, backend_id=backend_id)

    def _results(self, recording_id: str | None = None, backend_id: str | None = None) -> list[dict[str, Any]]:
        deduped: dict[str, tuple[int, dict[str, Any]]] = {}
        for index, item in enumerate(self._read_jsonl(self.runner.results_path)):
            result_id = item.get("result_id")
            if not isinstance(result_id, str):
                continue
            if recording_id is not None and item.get("recording_id") != recording_id:
                continue
            if backend_id is not None and item.get("backend_id") != backend_id:
                continue
            deduped[result_id] = (index, item)
        return [entry for _, entry in sorted(deduped.values(), key=lambda entry: entry[0])]

    def summary(self) -> dict[str, Any]:
        with self.summary_lock:
            results = self._results()
            ratings = self.list_ratings()
            grouped: dict[tuple[str, bool], list[dict[str, Any]]] = defaultdict(list)
            for item in results:
                backend_id = str(item.get("backend_id", ""))
                grouped[(backend_id, bool(item.get("warm", False)))].append(item)

            entries = []
            for (backend_id, warm), group in sorted(grouped.items(), key=lambda item: item[0]):
                count = len(group)
                errors = [item for item in group if item.get("error")]
                scored = [item for item in group if not item.get("error")]
                scores = [
                    item.get("scores")
                    for item in scored
                    if isinstance(item.get("scores"), dict)
                ]
                word_accuracy = [
                    score.get("word_accuracy") for score in scores if isinstance(score.get("word_accuracy"), (int, float))
                ]
                keyword_recall = [
                    score.get("keyword_recall")
                    for score in scores
                    if score.get("keyword_recall") is not None
                    and isinstance(score.get("keyword_recall"), (int, float))
                ]
                wall_ms = [item.get("wall_ms") for item in scored if isinstance(item.get("wall_ms"), (int, float))]
                realtime = [
                    item.get("realtime_factor")
                    for item in scored
                    if isinstance(item.get("realtime_factor"), (int, float))
                ]
                manual_rating_counts = {value: 0 for value in VALID_RATINGS}
                for item in group:
                    rating = ratings.get(str(item.get("result_id", "")), {}).get("rating")
                    if rating in manual_rating_counts:
                        manual_rating_counts[rating] += 1
                sample = next((item for item in group if item.get("backend_name")), {})
                entries.append(
                    {
                        "backend_id": backend_id,
                        "backend_name": str(sample.get("backend_name", backend_id)),
                        "family": str(sample.get("family", "")),
                        "warm": warm,
                        "count": count,
                        "error_count": len(errors),
                        "word_accuracy_mean": self._mean(word_accuracy),
                        "keyword_recall_mean": self._mean(keyword_recall),
                        "latency_mean_ms": self._mean(wall_ms),
                        "realtime_factor_mean": self._mean(realtime),
                        "manual_rating_counts": manual_rating_counts,
                    }
                )

            result_ids = {
                str(item.get("result_id"))
                for item in results
                if isinstance(item.get("result_id"), str)
            }
            return {
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "summary": entries,
                "counts": {
                    "results": len(results),
                    "rated": len(result_ids.intersection(ratings.keys())),
                },
            }

    def _results_with_ratings(self) -> list[dict[str, Any]]:
        ratings = self.list_ratings()
        output: list[dict[str, Any]] = []
        for result in self._results():
            result_id = result.get("result_id")
            if not isinstance(result_id, str):
                continue
            rating = ratings.get(result_id, {})
            row = dict(result)
            row["manual_rating"] = rating.get("rating")
            if "corrected_text" in rating:
                row["manual_corrected_text"] = rating.get("corrected_text")
            row["manual_created_at"] = rating.get("created_at")
            row["manual_updated_at"] = rating.get("updated_at")
            output.append(row)
        return output

    def _export_row(self, row: dict[str, Any]) -> dict[str, Any]:
        scores = row.get("scores")
        result = {
            "result_id": row.get("result_id"),
            "recording_id": row.get("recording_id"),
            "backend_id": row.get("backend_id"),
            "backend_name": row.get("backend_name"),
            "family": row.get("family"),
            "repetition": row.get("repetition"),
            "reference": row.get("reference"),
            "text": row.get("text"),
            "error": row.get("error"),
            "wall_ms": row.get("wall_ms"),
            "backend_ms": row.get("backend_ms"),
            "load_ms": row.get("load_ms"),
            "audio_seconds": row.get("audio_seconds"),
            "realtime_factor": row.get("realtime_factor"),
            "keywords": row.get("keywords"),
            "warm": row.get("warm", False),
            "phase": "warm" if row.get("warm") else "cold",
            "wer": scores.get("wer") if isinstance(scores, dict) else None,
            "word_accuracy": scores.get("word_accuracy") if isinstance(scores, dict) else None,
            "cer": scores.get("cer") if isinstance(scores, dict) else None,
            "character_accuracy": scores.get("character_accuracy") if isinstance(scores, dict) else None,
            "keyword_recall": scores.get("keyword_recall") if isinstance(scores, dict) else None,
            "exact_normalized": scores.get("exact_normalized") if isinstance(scores, dict) else None,
            "manual_rating": row.get("manual_rating"),
            "manual_corrected_text": row.get("manual_corrected_text"),
            "manual_created_at": row.get("manual_created_at"),
            "manual_updated_at": row.get("manual_updated_at"),
        }
        return {key: self._flatten_value(value) for key, value in result.items()}

    def export(self, fmt: str) -> tuple[str, str, bytes]:
        format_name = fmt.lower()
        now = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
        rows = self._results_with_ratings()

        if format_name == "json":
            payload = {
                "exported_at": datetime.now(timezone.utc).isoformat(),
                "results": rows,
                "ratings": self.list_ratings(),
            }
            return (
                "application/json; charset=utf-8",
                f"sttbench-results-{now}.json",
                json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            )

        if format_name == "csv":
            buffer = StringIO()
            headers = [
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
            writer = csv.DictWriter(buffer, fieldnames=headers, extrasaction="ignore")
            writer.writeheader()
            for row in rows:
                writer.writerow(self._export_row(row))
            return (
                "text/csv; charset=utf-8",
                f"sttbench-results-{now}.csv",
                buffer.getvalue().encode("utf-8"),
            )

        raise ValueError("format must be json or csv")

    def save_recording(self, case_id: str, wav_bytes: bytes) -> dict[str, Any]:
        recording_id = uuid4().hex
        wav_path = self.recordings_dir / f"{recording_id}.wav"
        wav_path.write_bytes(wav_bytes)
        cases = {item["id"]: item for item in self.corpus()["cases"]}
        case = cases.get(case_id, {})
        metadata = {
            "id": recording_id,
            "case_id": case_id,
            "reference": case.get("text", ""),
            "keywords": case.get("keywords", []),
            "audio_path": str(wav_path),
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        with (self.recordings_dir / f"{recording_id}.json").open("w") as target:
            json.dump(metadata, target, indent=2)
        return metadata

    def start_job(self, payload: dict[str, Any]) -> Job:
        recordings = {item["id"]: item for item in self.recordings()}
        recording = recordings[payload["recording_id"]]
        job = Job(id=uuid4().hex)
        with self.jobs_lock:
            self.jobs[job.id] = job

        def execute() -> None:
            job.status = "running"
            try:
                job.results = self.runner.run(
                    recording_id=recording["id"],
                    audio_path=recording["audio_path"],
                    backend_ids=payload["backend_ids"],
                    reference=payload.get("reference", recording["reference"]),
                    keywords=payload.get("keywords", recording["keywords"]),
                    language=payload.get("language", "en"),
                    prompt=payload.get("prompt"),
                    warmups=int(payload.get("warmups", 0)),
                    repetitions=int(payload.get("repetitions", 1)),
                    on_result=lambda result: job.results.append(result),
                )
                job.status = "complete"
            except Exception as error:
                job.error = str(error)
                job.status = "failed"

        self.executor.submit(execute)
        return job


class Handler(BaseHTTPRequestHandler):
    server_version = "STTBench/0.1"

    @property
    def app(self) -> BenchmarkApplication:
        return self.server.app  # type: ignore[attr-defined]

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header(
            "Access-Control-Allow-Headers", "Content-Type, X-STTBench-Case",
        )

    def _json(self, value: Any, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self, maximum: int = 32 * 1024 * 1024) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        if length > maximum:
            raise ValueError("Request is too large")
        return self.rfile.read(length)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self._cors()
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        try:
            if path == "/api/status":
                self._json({"ok": True, "version": 1})
            elif path == "/api/corpus":
                self._json(self.app.corpus())
            elif path == "/api/summary":
                self._json(self.app.summary())
            elif path == "/api/results":
                query = parse_qs(parsed.query)
                recording_id = query.get("recording_id", [None])[0]
                backend_id = query.get("backend_id", [None])[0]
                self._json(
                    {
                        "results": self.app.list_results(
                            recording_id=recording_id or None,
                            backend_id=backend_id or None,
                        )
                    }
                )
            elif path == "/api/export":
                query = parse_qs(parsed.query)
                format_name = query.get("format", ["json"])[0]
                content_type, filename, payload = self.app.export(format_name)
                self.send_response(HTTPStatus.OK)
                self._cors()
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            elif path == "/api/backends":
                self._json({"backends": self.app.runner.registry.public_specs()})
            elif path == "/api/recordings":
                self._json({"recordings": self.app.recordings()})
            elif path == "/api/ratings":
                query = parse_qs(parsed.query)
                if "result_id" in query:
                    result_id = query["result_id"][0]
                    ratings = self.app.list_ratings()
                    if result_id not in ratings:
                        self._json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
                        return
                    self._json(ratings[result_id])
                else:
                    self._json({"ratings": self.app.list_ratings()})
            elif path.startswith("/api/jobs/"):
                job_id = path.rsplit("/", 1)[-1]
                job = self.app.jobs.get(job_id)
                self._json(job.as_dict() if job else {"error": "Not found"}, 200 if job else 404)
            else:
                self._json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
        except ValueError as error:
            self._json({"error": str(error)}, HTTPStatus.BAD_REQUEST)
        except Exception as error:
            self._json({"error": str(error)}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        try:
            if parsed.path == "/api/recordings":
                case_id = parse_qs(parsed.query).get("case_id", ["custom"])[0]
                body = self._body()
                if not body.startswith(b"RIFF") or body[8:12] != b"WAVE":
                    self._json({"error": "Expected a PCM WAV recording"}, 400)
                    return
                self._json(self.app.save_recording(case_id, body), HTTPStatus.CREATED)
            elif parsed.path == "/api/corpus":
                body = self._body()
                body_text = body.decode("utf-8")
                if self.headers.get("Content-Type", "").startswith("application/json"):
                    payload = json.loads(body_text)
                else:
                    payload = body_text
                self._json(self.app.replace_corpus(payload))
            elif parsed.path == "/api/jobs":
                payload = json.loads(self._body().decode())
                self._json(self.app.start_job(payload).as_dict(), HTTPStatus.ACCEPTED)
            elif parsed.path == "/api/ratings":
                payload = json.loads(self._body().decode())
                self._json(self.app.upsert_rating(payload), HTTPStatus.CREATED)
            else:
                self._json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
        except (KeyError, ValueError, json.JSONDecodeError) as error:
            self._json({"error": str(error)}, HTTPStatus.BAD_REQUEST)
        except Exception as error:
            self._json({"error": str(error)}, HTTPStatus.INTERNAL_SERVER_ERROR)


    def log_message(self, format: str, *args: Any) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the local STT benchmark service")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    app = BenchmarkApplication(root)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.app = app  # type: ignore[attr-defined]
    print(f"STT benchmark service: http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        app.runner.close()
        app.executor.shutdown(wait=False, cancel_futures=True)
        server.server_close()


if __name__ == "__main__":
    main()
