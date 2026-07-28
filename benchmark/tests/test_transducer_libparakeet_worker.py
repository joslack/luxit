from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path
import struct
import wave
import unittest
import sys
from unittest import mock


def _load_worker_module():
    path = Path(__file__).resolve().parents[1] / "workers/transducer_libparakeet_worker.py"
    worker_dir = path.parent
    sys.path.insert(0, str(worker_dir))
    spec = importlib.util.spec_from_file_location("transducer_libparakeet_worker", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load worker module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _write_wav(path: Path, sample_rate: int = 16000, channels: int = 1, width: int = 2) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if width not in {1, 2}:
        raise ValueError("Unsupported sample width for test")

    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(width)
        handle.setframerate(sample_rate)
        if width == 1:
            handle.writeframes(struct.pack("<bb", 0, 0))
        else:
            handle.writeframes(struct.pack("<hh", 0, 0))


class ParakeetLibWorkerTests(unittest.TestCase):
    def test_worker_load_rejects_missing_library(self) -> None:
        module = _load_worker_module()
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            model_path = directory_path / "model.ggml"
            model_path.write_bytes(b"model")
            worker = module.ParakeetLibWorker()
            payload = {
                "model_path": str(model_path),
                "options": {
                    "library": str(directory_path / "missing.dylib"),
                },
            }
            with self.assertRaisesRegex(RuntimeError, "Missing path: .*missing.dylib"):
                worker.load(payload)

    def test_worker_rejects_noncanonical_wav(self) -> None:
        module = _load_worker_module()
        with tempfile.TemporaryDirectory() as directory:
            bad = Path(directory) / "bad.wav"
            _write_wav(bad, sample_rate=8000, channels=1, width=2)
            with self.assertRaisesRegex(ValueError, "Expected sample rate"):
                module._read_wav_mono_16k_pcm16(str(bad))

    def test_worker_reports_missing_ggml_library(self) -> None:
        module = _load_worker_module()
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            model_path = directory_path / "model.ggml"
            model_path.write_bytes(b"model")
            fake_library_path = directory_path / "fake-libparakeet.dylib"
            fake_library_path.write_bytes(b"")
            worker = module.ParakeetLibWorker()
            payload = {
                "model_path": str(model_path),
                "options": {
                    "library": str(fake_library_path),
                },
            }
            fake_lib = mock.Mock()
            with mock.patch.object(module.ctypes, "CDLL", return_value=fake_lib):
                with mock.patch.object(module, "_bind_library"):
                    with mock.patch.object(
                        module,
                        "_bind_ggml_library",
                        side_effect=RuntimeError("libggml library failed to load"),
                    ):
                        with self.assertRaisesRegex(RuntimeError, "libggml library failed to load"):
                            worker.load(payload)
