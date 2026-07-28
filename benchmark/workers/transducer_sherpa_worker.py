#!/usr/bin/env python3
from __future__ import annotations

import importlib
import json
from pathlib import Path

from transducer_worker_utils import error_payload, read_wav_float32, run_command


class SherpaWorker:
    def __init__(self) -> None:
        self.options: dict[str, object] = {}
        self.ready = False
        self.recognizer = None
        self.config = None
        self.support_prompt = False
        self.using_python_api = False

    def load(self, payload: dict[str, object]) -> dict[str, object]:
        self.options = dict(payload.get("options", {}))
        self.support_prompt = bool(self.options.get("supports_prompt", False))
        required_paths = [
            str(self.options.get("encoder_path", "")),
            str(self.options.get("decoder_path", "")),
            str(self.options.get("joiner_path", "")),
            str(self.options.get("tokens_path", "")),
        ]
        for required_path in required_paths:
            if required_path and not Path(required_path).exists():
                raise RuntimeError(f"Missing path: {required_path}")

        try:
            module = importlib.import_module("sherpa_onnx")
        except ModuleNotFoundError as error:
            raise RuntimeError("Missing Python module: sherpa_onnx") from error

        if hasattr(module, "OnlineRecognizerConfig") and hasattr(module, "OnlineRecognizer"):
            self.using_python_api = True
            try:
                self._build_online_api(module)
            except Exception as error:
                raise RuntimeError(f"Unexpected sherpa_onnx API shape: {error}") from error
        elif hasattr(module, "OfflineRecognizerConfig") and hasattr(module, "OfflineRecognizer"):
            self.using_python_api = True
            try:
                self._build_offline_api(module)
            except Exception as error:
                raise RuntimeError(f"Unexpected sherpa_onnx API shape: {error}") from error
        else:
            self.using_python_api = False

        self.ready = True
        return {
            "status": "loaded",
            "backend": "sherpa-onnx",
            "model": str(payload.get("model", "")),
            "api_mode": "python" if self.using_python_api else "fallback",
        }

    def _build_offline_api(self, module: object) -> None:
        config = {}
        if hasattr(module, "OfflineRecognizerConfig") and hasattr(module.OfflineRecognizerConfig, "from_dict"):
            model_config = {
                "transducer": {
                    "encoder": self.options.get("encoder_path"),
                    "decoder": self.options.get("decoder_path"),
                    "joiner": self.options.get("joiner_path"),
                },
                "tokens": self.options.get("tokens_path"),
                "provider": self.options.get("provider", "cpu"),
                "num_threads": int(self.options.get("num_threads", 4)),
            }
            config = module.OfflineRecognizerConfig.from_dict(
                {
                    "feat_config": {"sample_rate": 16000, "feature_dim": 80},
                    "model_config": model_config,
                    "decoding_method": self.options.get("decoding_method", "greedy_search"),
                }
            )
        else:
            raise RuntimeError("OfflineRecognizerConfig.from_dict is unavailable")
        recognizer = getattr(module, "OfflineRecognizer")
        self.recognizer = recognizer(config)
        self.config = config

    def _build_online_api(self, module: object) -> None:
        config = {}
        if hasattr(module, "OnlineRecognizerConfig") and hasattr(module.OnlineRecognizerConfig, "from_dict"):
            model_config = {
                "transducer": {
                    "encoder": self.options.get("encoder_path"),
                    "decoder": self.options.get("decoder_path"),
                    "joiner": self.options.get("joiner_path"),
                },
                "tokens": self.options.get("tokens_path"),
                "provider": self.options.get("provider", "cpu"),
                "num_threads": int(self.options.get("num_threads", 4)),
            }
            config = module.OnlineRecognizerConfig.from_dict(
                {
                    "feat_config": {"sample_rate": 16000, "feature_dim": 80},
                    "model_config": model_config,
                    "decoding_method": self.options.get("decoding_method", "greedy_search"),
                    "endpoint_config": {},
                }
            )
        else:
            raise RuntimeError("OnlineRecognizerConfig.from_dict is unavailable")
        recognizer_cls = getattr(module, "OnlineRecognizer")
        self.recognizer = recognizer_cls(config)
        self.config = config

    def _transcribe_with_python_api(self, audio_path: str) -> str:
        samples, sample_rate = read_wav_float32(audio_path)
        if not samples:
            return ""

        module = importlib.import_module("sherpa_onnx")
        if hasattr(module, "OfflineStream") or hasattr(self.recognizer, "create_stream"):
            stream = self.recognizer.create_stream()  # type: ignore[call-arg]
            self.recognizer.accept_waveform(stream, sample_rate, samples)  # type: ignore[call-arg]
            while self.recognizer.is_ready(stream):  # type: ignore[call-arg]
                self.recognizer.decode_stream(stream)  # type: ignore[call-arg]
            result = self.recognizer.get_result(stream)  # type: ignore[call-arg]
            if isinstance(result, dict):
                return str(result.get("text", ""))
            return str(result)
        if hasattr(self.recognizer, "__call__"):
            result = self.recognizer(samples, sample_rate)  # type: ignore[call-arg]
            if isinstance(result, dict):
                return str(result.get("text", ""))
            return str(result)
        raise RuntimeError("sherpa-onnx recognizer API is unsupported by benchmark worker")

    def _transcribe_with_fallback_command(self, payload: dict[str, object]) -> dict[str, object]:
        command = [
            "sherpa-onnx",
            "recognize",
            str(payload.get("audio_path") or payload.get("audio")),
            "--encoder",
            str(self.options.get("encoder_path", "")),
            "--decoder",
            str(self.options.get("decoder_path", "")),
            "--joiner",
            str(self.options.get("joiner_path", "")),
            "--tokens",
            str(self.options.get("tokens_path", "")),
            "--provider",
            str(self.options.get("provider", "cpu")),
            "--num-threads",
            str(self.options.get("num_threads", 4)),
        ]
        returncode, _, parsed = run_command(command, float(self.options.get("timeout_seconds", 600)))
        output = json.loads(parsed)
        if returncode != 0:
            return error_payload(
                output.get("metadata", {}).get("stderr", "sherpa-onnx fallback command failed"),
                returncode=returncode,
                command=command,
            )
        return output

    def transcribe(self, payload: dict[str, object]) -> dict[str, object]:
        if not self.ready:
            raise RuntimeError("Worker is not loaded")
        if payload.get("prompt") and not self.support_prompt:
            return error_payload("Prompt is not supported by this backend")
        language = str(payload.get("language") or "")
        if language not in {"", "en", "auto"}:
            return error_payload(f"Unsupported language for this backend: {language}")

        audio_path = str(payload.get("audio_path") or payload.get("audio", ""))
        if not audio_path:
            return error_payload("Missing audio path")
        if not Path(audio_path).exists():
            return error_payload(f"Missing path: {audio_path}")

        if self.using_python_api:
            try:
                text = self._transcribe_with_python_api(audio_path)
            except Exception as error:
                return error_payload(f"sherpa-onnx Python API failed: {error}")
            return {
                "text": text,
                "segments": [],
                "words": [],
                "metadata": {
                    "backend": "sherpa-onnx",
                    "api": "python",
                },
            }
        return self._transcribe_with_fallback_command(payload)

    def close(self) -> None:
        self.ready = False
        self.config = None
        self.recognizer = None


def main() -> None:
    worker = SherpaWorker()
    while True:
        try:
            line = input()
        except EOFError:
            break
        if not line.strip():
            continue
        message = json.loads(line)
        if message.get("type") == "load":
            response = worker.load(message)
        elif message.get("type") == "transcribe":
            response = worker.transcribe(message)
        elif message.get("type") == "shutdown":
            response = {"status": "shutdown"}
            worker.close()
            print(json.dumps(response, separators=(",", ":")))
            break
        else:
            response = error_payload(f"Unsupported message type: {message.get('type')}")
        print(json.dumps(response, separators=(",", ":")))


if __name__ == "__main__":
    main()
