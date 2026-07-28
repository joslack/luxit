from __future__ import annotations

import json
import hashlib
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from .metrics import score
from .registry import BackendRegistry
from .types import TranscriptRequest, TranscriptResult


class BenchmarkRunner:
    def __init__(self, benchmark_root: Path):
        self.root = benchmark_root
        self.registry = BackendRegistry(benchmark_root)
        self.lock = threading.Lock()
        self.data_dir = self.root / "data"
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.results_path = self.data_dir / "results.jsonl"

    def _adapter(self, backend_id: str):
        return self.registry.create(backend_id)

    @staticmethod
    def _result_id(recording_id: str, backend_id: str, repetition: int, warm: bool) -> str:
        marker = "warm" if warm else "cold"
        payload = f"{recording_id}|{backend_id}|{marker}|{repetition}"
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:24]

    def _result_item(
        self,
        recording_id: str,
        adapter,
        reference: str,
        keywords: list[str],
        repetition: int,
        transcript: TranscriptResult,
    ) -> dict[str, Any]:
        result: dict[str, Any] = {
            "result_id": self._result_id(
                recording_id=recording_id,
                backend_id=adapter.spec.id,
                repetition=repetition,
                warm=bool(repetition),
            ),
            "recording_id": recording_id,
            "backend_id": adapter.spec.id,
            "backend_name": adapter.spec.name,
            "family": adapter.spec.family,
            "repetition": repetition,
            "reference": reference,
            "keywords": keywords,
            "created_at": datetime.now(timezone.utc).isoformat(),
            **transcript.as_dict(),
        }
        result["scores"] = (
            score(reference, transcript.text, keywords) if not transcript.error else None
        )
        return result

    def run(
        self,
        recording_id: str,
        audio_path: str,
        backend_ids: list[str],
        reference: str,
        keywords: list[str],
        language: str | None,
        prompt: str | None,
        warmups: int,
        repetitions: int,
        on_result: Callable[[dict[str, Any]], None] | None = None,
    ) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        # One active inference at a time keeps the machine's compute and memory
        # bandwidth comparable across backends.
        with self.lock:
            for backend_id in backend_ids:
                adapter = self._adapter(backend_id)
                request = TranscriptRequest(
                    audio_path=audio_path,
                    language=language,
                    prompt=prompt if adapter.spec.capabilities.prompt else None,
                    word_timestamps=False,
                )
                try:
                    # Explicit cold pass always runs once from a fresh adapter.
                    cold = adapter.transcribe(request)
                    item = self._result_item(
                        recording_id=recording_id,
                        adapter=adapter,
                        reference=reference,
                        keywords=keywords,
                        repetition=0,
                        transcript=cold,
                    )
                    item["warm"] = False
                    results.append(item)
                    with self.results_path.open("a") as target:
                        target.write(json.dumps(item, separators=(",", ":")) + "\n")
                    if on_result:
                        on_result(item)

                    # Optional warmups prime the backend; they are not recorded.
                    for _ in range(max(0, warmups)):
                        adapter.transcribe(request)

                    # Warm repetitions measure steady-state behavior.
                    for repetition in range(1, max(1, repetitions) + 1):
                        transcript = adapter.transcribe(request)
                        result = self._result_item(
                            recording_id=recording_id,
                            adapter=adapter,
                            reference=reference,
                            keywords=keywords,
                            repetition=repetition,
                            transcript=transcript,
                        )
                        result["warm"] = repetition > 0
                        results.append(result)
                        with self.results_path.open("a") as target:
                            target.write(json.dumps(result, separators=(",", ":")) + "\n")
                        if on_result:
                            on_result(result)
                finally:
                    adapter.close()
        return results

    def close(self) -> None:
        return
