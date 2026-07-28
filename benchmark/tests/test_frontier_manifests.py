from __future__ import annotations

import unittest
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from benchmark.sttbench.registry import BackendRegistry


class FrontierManifestTests(unittest.TestCase):
    EXPECTED_IDS = {
        "frontier-qwen3-asr-mlx-0.6b",
        "frontier-qwen3-asr-mlx-1.7b",
        "frontier-qwen3-asr-pure-c",
        "frontier-sensevoice-coreml-int8",
        "frontier-granite-4.0-mlx-8bit",
        "frontier-voxtral-realtime-mlx-4bit",
        "frontier-cohere-coreml",
        "frontier-canary-1b-v2-mlx-q8",
    }

    def setUp(self) -> None:
        self.registry = BackendRegistry(Path(__file__).resolve().parents[1])

    def test_frontier_manifests_exist(self):
        frontier_specs = [
            item for item in self.registry.specs.values() if item.id.startswith("frontier-")
        ]
        self.assertGreater(len(frontier_specs), 0)
        actual_ids = {item.id for item in frontier_specs}
        self.assertTrue(
            self.EXPECTED_IDS.issubset(actual_ids),
            f"Missing expected frontier ids: {sorted(self.EXPECTED_IDS - actual_ids)}",
        )

    def test_frontier_manifest_contract_fields(self):
        frontier_specs = [
            item for item in self.registry.specs.values() if item.id.startswith("frontier-")
        ]
        for spec in frontier_specs:
            self.assertEqual(spec.family, "frontier-asr")
            self.assertTrue(spec.command, f"{spec.id}: command is missing")
            self.assertIn(spec.protocol, {"jsonl-worker", "command"}, spec.id)
            self.assertTrue(
                spec.required_commands or spec.required_paths or spec.required_python_modules,
                f"{spec.id}: no availability requirements declared",
            )
            script_candidate = Path(spec.command[1]).resolve()
            self.assertTrue(script_candidate.exists(), f"{spec.id}: worker script not found")

            if spec.protocol == "jsonl-worker":
                self.assertIn("frontier_asr_jsonl_worker.py", script_candidate.name)
            if spec.protocol == "command":
                self.assertEqual(spec.command[0], "python")

    def test_frontier_availability_is_informative(self):
        frontier_specs = [
            item for item in self.registry.specs.values() if item.id.startswith("frontier-")
        ]
        for spec in frontier_specs:
            available, reasons = self.registry.availability(spec)
            if not available:
                self.assertTrue(
                    all(isinstance(item, str) and item for item in reasons),
                    f"{spec.id}: non-empty availability reasons expected",
                )
