from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
import unittest


def _exchange(process: subprocess.Popen[str], payload: dict[str, object]) -> dict[str, object]:
    process.stdin.write(json.dumps(payload) + "\n")  # type: ignore[union-attr]
    process.stdin.flush()
    response_line = process.stdout.readline()  # type: ignore[union-attr]
    return json.loads(response_line)


def _worker_script() -> Path:
    return Path(__file__).resolve().parents[1] / "workers/whisper_cpp_server_worker.py"


class WhisperCppServerWorkerTests(unittest.TestCase):
    def test_load_fails_when_model_is_missing(self) -> None:
        script = _worker_script()
        with subprocess.Popen(
            [sys.executable, str(script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as process:
            assert process.stdin is not None
            assert process.stdout is not None
            response = _exchange(
                process,
                {
                    "type": "load",
                    "backend_id": "whisper-cpp-baseline-v3-turbo-q5_0",
                    "model": "ggml-large-v3-turbo-q5_0.bin",
                    "model_path": "/missing/model.bin",
                    "options": {
                        "threads": 6,
                        "beam_size": 5,
                        "best_of": 5,
                        "temperature": 0,
                        "temperature_fallback": True,
                        "no_context": True,
                        "no_timestamps": True,
                        "supports_prompt": True,
                        "supports_language_override": False,
                        "supports_word_timestamps": False,
                        "flash_attention": True,
                        "whisper_server_binary": "/opt/homebrew/bin/whisper-server",
                    },
                },
            )
            self.assertIn("error", response)

            shutdown = _exchange(process, {"type": "shutdown"})
            self.assertEqual(shutdown.get("status"), "shutdown")

    def test_worker_real_cold_and_warm_smoke(self) -> None:
        if shutil.which("whisper-server") is None:
            self.skipTest("whisper-server is not installed")
        model_path = (
            Path.home()
            / "Library"
            / "Application Support"
            / "EdgeWhisper"
            / "Models"
            / "ggml-large-v3-turbo-q5_0.bin"
        )
        if not model_path.is_file():
            self.skipTest("EdgeWhisper q5_0 model is not available")
        audio_path = Path(__file__).resolve().parents[1] / "data/reference/1272-128104-0000.wav"
        if not audio_path.is_file():
            self.skipTest("LibriSpeech smoke sample is not available")

        script = _worker_script()
        with subprocess.Popen(
            [sys.executable, str(script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as process:
            assert process.stdin is not None
            assert process.stdout is not None

            load_response = _exchange(
                process,
                {
                    "type": "load",
                    "backend_id": "whisper-cpp-fast-greedy-v3-turbo-q5_0",
                    "model": "ggml-large-v3-turbo-q5_0.bin",
                    "model_path": str(model_path),
                    "options": {
                        "threads": 6,
                        "beam_size": 1,
                        "best_of": 1,
                        "temperature": 0,
                        "temperature_fallback": False,
                        "no_context": True,
                        "no_timestamps": True,
                        "supports_prompt": True,
                        "supports_language_override": False,
                        "supports_word_timestamps": False,
                        "flash_attention": True,
                        "whisper_server_binary": "/opt/homebrew/bin/whisper-server",
                    },
                },
            )
            self.assertIn("status", load_response)
            self.assertEqual(load_response.get("status"), "loaded")
            self.assertIn("load_ms", load_response)
            self.assertGreater(load_response["load_ms"], 0)

            request = {
                "type": "transcribe",
                "audio_path": str(audio_path),
                "language": "en",
                "prompt": "test prompt",
                "word_timestamps": False,
            }
            cold = _exchange(process, request)
            self.assertNotIn("error", cold)
            self.assertIn("text", cold)
            self.assertTrue(str(cold["text"]).strip())

            warm = _exchange(process, request)
            self.assertNotIn("error", warm)
            self.assertIn("text", warm)
            self.assertTrue(str(warm["text"]).strip())
            self.assertIn("backend_ms", warm)

            shutdown = _exchange(process, {"type": "shutdown"})
            self.assertEqual(shutdown.get("status"), "shutdown")
