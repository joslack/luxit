from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from sttbench.registry import BackendRegistry


class WhisperBackendManifestTests(unittest.TestCase):
    def test_whisper_backends_are_present(self) -> None:
        registry = BackendRegistry(Path(__file__).resolve().parents[1])
        specs = [
            item
            for item in registry.public_specs()
            if str(item["family"]) == "whisper"
        ]
        ids = {item["id"] for item in specs}
        self.assertTrue(
            {
                "whisper-cpp-baseline-v3-turbo-q5_0",
                "whisper-cpp-fast-greedy-v3-turbo-q5_0",
                "whisper-cpp-fast-distil-large-v3",
                "mlx-whisper-turbo-fp16",
                "mlx-whisper-distil-large-v3",
                "whisperkit-large-v3-turbo",
                "whisperkit-distil-large-v3",
            }.issubset(ids),
            "Whisper-family backends are missing from benchmark/backends",
        )

    def test_whisperkit_turbo_disables_broken_prompt_path(self) -> None:
        registry = BackendRegistry(Path(__file__).resolve().parents[1])
        spec = registry.specs["whisperkit-large-v3-turbo"]
        self.assertFalse(spec.capabilities.prompt)
        self.assertFalse(spec.options["supports_prompt"])

    def test_unavailable_reason_for_missing_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            bench_root = Path(root)
            backends = bench_root / "backends"
            backends.mkdir(parents=True)
            manifest = {
                "id": "whisper-test-missing",
                "name": "Mock whisper missing backend",
                "family": "whisper",
                "protocol": "command",
                "command": ["python3", "/bin/true"],
                "description": "Dependency probe",
                "model": "mock.bin",
                "model_path": "/tmp/nonexistent/mock.bin",
                "license": "MIT",
                "source_url": "https://example.invalid",
                "required_commands": ["definitely-missing-command"],
                "required_paths": ["/tmp/nonexistent/mock.bin"],
                "required_python_modules": ["definitely_missing_module"],
                "capabilities": {
                    "languages": ["en"],
                    "prompt": False,
                    "word_timestamps": False,
                    "segment_timestamps": False,
                    "streaming": False,
                    "persistent": False,
                },
                "options": {},
                "environment": {},
                "setup": "Test manifest",
            }
            (backends / "whisper-test-missing.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            registry = BackendRegistry(bench_root)
            public = registry.public_specs()
            self.assertEqual(len(public), 1)
            self.assertFalse(public[0]["available"])
            reason = " ".join(public[0]["unavailable_reasons"]).lower()
            self.assertIn("missing command", reason)
            self.assertIn("missing path", reason)
            self.assertIn("missing python module", reason)

    def test_whisper_cpp_bridge_rejects_unsupported_prompt(self) -> None:
        bridge = Path(__file__).resolve().parents[1] / "workers/whisper_cpp_cli_bridge.py"
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / "sample.wav"
            audio.write_bytes(b"RIFF")
            model = Path(directory) / "model.bin"
            model.write_bytes(b"mock")
            command = [
                sys.executable,
                str(bridge),
                "--backend-id",
                "whisper-cpp-test",
                "--audio",
                str(audio),
                "--model-path",
                str(model),
                "--language",
                "en",
                "--prompt",
                "do not use",
                "--supports-prompt",
                "false",
                "--supports-language-override",
                "false",
                "--supports-word-timestamps",
                "false",
                "--word-timestamps",
                "false",
                "--no-context",
                "true",
                "--no-timestamps",
                "true",
                "--beam-size",
                "1",
                "--best-of",
                "1",
                "--temperature",
                "0",
                "--temperature-fallback",
                "false",
                "--strategy",
                "greedy",
                "--flash-attention",
                "true",
                "--whisper-binary",
                "/bin/echo",
                "--dry-run",
            ]
            process = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(process.returncode, 1)
            payload = json.loads(process.stdout.strip())
            self.assertIn("error", payload)
            self.assertIn("unsupported", payload["error"])

    def test_whisper_cpp_turbo_q5_profiles_use_persistent_jsonl_worker(self) -> None:
        registry = BackendRegistry(Path(__file__).resolve().parents[1])
        for backend_id in {
            "whisper-cpp-baseline-v3-turbo-q5_0",
            "whisper-cpp-fast-greedy-v3-turbo-q5_0",
        }:
            spec = registry.specs[backend_id]
            self.assertEqual(spec.protocol, "jsonl-worker", f"{backend_id}: protocol mismatch")
            self.assertTrue(spec.capabilities.persistent, f"{backend_id}: expected persistent capability")
            self.assertEqual(Path(spec.command[1]).name, "whisper_cpp_server_worker.py")
            self.assertTrue(
                any(
                    str(path).endswith("whisper_cpp_server_worker.py")
                    for path in spec.required_paths
                ),
                f"{backend_id}: missing worker script path",
            )

    def test_whisper_cpp_turbo_q5_profile_options_remain_exact(self) -> None:
        registry = BackendRegistry(Path(__file__).resolve().parents[1])
        baseline = registry.specs["whisper-cpp-baseline-v3-turbo-q5_0"]
        fast = registry.specs["whisper-cpp-fast-greedy-v3-turbo-q5_0"]

        self.assertEqual(baseline.options["beam_size"], 5)
        self.assertEqual(baseline.options["best_of"], 5)
        self.assertTrue(baseline.options["temperature_fallback"])

        self.assertEqual(fast.options["beam_size"], 1)
        self.assertEqual(fast.options["best_of"], 1)
        self.assertFalse(fast.options["temperature_fallback"])
