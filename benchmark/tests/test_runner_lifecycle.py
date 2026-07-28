from __future__ import annotations

import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from sttbench.runner import BenchmarkRunner
from sttbench.types import Capabilities, TranscriptResult


@dataclass(frozen=True)
class _FakeSpec:
    id: str
    name: str
    family: str
    capabilities: Capabilities


class _FakeAdapter:
    def __init__(self, backend_id: str, warmups: int):
        self.spec = _FakeSpec(
            id=backend_id,
            name=f"{backend_id}-name",
            family="test",
            capabilities=Capabilities(prompt=False),
        )
        self.warmups = warmups
        self.calls = 0
        self.close_calls = 0

    def transcribe(self, request) -> TranscriptResult:  # type: ignore[type-arg]
        call_index = self.calls
        self.calls += 1
        return TranscriptResult(
            backend_id=self.spec.id,
            text=f"{self.spec.id}-{call_index}",
            wall_ms=10.0 + call_index,
            audio_seconds=1.0,
            warm=call_index > self.warmups,
        )

    def close(self) -> None:
        self.close_calls += 1


class RunnerLifecycleTests(unittest.TestCase):
    def test_run_emits_one_cold_and_many_warm_results_per_backend(self) -> None:
        warmups = 2
        repetitions = 3
        created: list[_FakeAdapter] = []

        def make_adapter(backend_id: str) -> _FakeAdapter:
            adapter = _FakeAdapter(backend_id, warmups)
            created.append(adapter)
            return adapter

        with tempfile.TemporaryDirectory() as directory:
            runner = BenchmarkRunner(Path(directory))
            runner._adapter = make_adapter  # type: ignore[assignment]
            callback_data: list[dict[str, Any]] = []
            results = runner.run(
                recording_id="recording-a",
                audio_path="/tmp/sample.wav",
                backend_ids=["alpha", "beta"],
                reference="hello",
                keywords=[],
                language="en",
                prompt=None,
                warmups=warmups,
                repetitions=repetitions,
                on_result=callback_data.append,
            )

            self.assertEqual(len(results), 2 * (1 + repetitions))
            self.assertEqual(len(callback_data), 2 * (1 + repetitions))

            first_backend = [item for item in results if item["backend_id"] == "alpha"]
            second_backend = [item for item in results if item["backend_id"] == "beta"]
            self.assertEqual([item["repetition"] for item in first_backend], [0, 1, 2, 3])
            self.assertEqual([item["repetition"] for item in second_backend], [0, 1, 2, 3])
            self.assertEqual([item["warm"] for item in first_backend], [False, True, True, True])
            self.assertEqual([item["warm"] for item in second_backend], [False, True, True, True])
            self.assertEqual(created[0].calls, 1 + warmups + repetitions)
            self.assertEqual(created[1].calls, 1 + warmups + repetitions)
            self.assertEqual(created[0].close_calls, 1)
            self.assertEqual(created[1].close_calls, 1)

        first_ids = [item["result_id"] for item in results]
        with tempfile.TemporaryDirectory() as directory:
            runner = BenchmarkRunner(Path(directory))
            runner._adapter = make_adapter  # type: ignore[assignment]
            rerun = runner.run(
                recording_id="recording-a",
                audio_path="/tmp/sample.wav",
                backend_ids=["alpha", "beta"],
                reference="hello",
                keywords=[],
                language="en",
                prompt=None,
                warmups=warmups,
                repetitions=repetitions,
            )

        self.assertEqual(first_ids, [item["result_id"] for item in rerun])


if __name__ == "__main__":
    unittest.main()
