from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


def _exchange(process: subprocess.Popen[str], payload: dict) -> dict:
    process.stdin.write(json.dumps(payload) + "\n")  # type: ignore[union-attr]
    process.stdin.flush()
    response = process.stdout.readline()  # type: ignore[union-attr]
    return json.loads(response)


class MLXJsonlWorkerTests(unittest.TestCase):
    def test_worker_load_transcribe_protocol(self) -> None:
        worker = Path(__file__).resolve().parents[1] / "workers/mlx_whisper_worker.py"
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / "sample.wav"
            audio.write_bytes(b"RIFF")
            environment = dict(os.environ)
            environment["STTBENCH_MOCK_MLX_WORKER"] = "1"
            with subprocess.Popen(
                [sys.executable, str(worker)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=environment,
            ) as process:
                assert process.stdin is not None
                assert process.stdout is not None

                load_response = _exchange(
                    process,
                    {
                        "type": "load",
                        "backend_id": "mlx-whisper-turbo-fp16",
                        "model": "mlx-community/whisper-large-v3-turbo-asr-fp16",
                        "model_path": str(Path(directory) / "model"),
                        "options": {
                            "engine": "mlx_audio",
                            "language_mode": "multilingual",
                            "supports_word_timestamps": False,
                            "beam_size": 1,
                            "best_of": 1,
                        },
                    },
                )
                self.assertIn("model_id", load_response)

                transcribe_response = _exchange(
                    process,
                    {
                        "type": "transcribe",
                        "audio_path": str(audio),
                        "language": "en",
                        "word_timestamps": False,
                        "prompt": "hello",
                        "options": {
                            "beam_size": 1,
                            "best_of": 1,
                        },
                    },
                )
                self.assertIn("text", transcribe_response)
                self.assertNotIn("error", transcribe_response)

                shutdown_response = _exchange(
                    process, {"type": "shutdown"}
                )
                self.assertIn("status", shutdown_response)
