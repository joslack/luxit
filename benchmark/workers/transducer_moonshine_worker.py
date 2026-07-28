#!/usr/bin/env python3
from __future__ import annotations

import json
import importlib
from pathlib import Path

from transducer_worker_utils import error_payload, read_wav_float32


class MoonshineWorker:
    def __init__(self) -> None:
        self.model_path = ""
        self.model_arch = ""
        self.ort_providers = "CPU"
        self.options: dict[str, object] = {}
        self.support_prompt = False
        self.supported_languages = ["en"]
        self.ready = False
        self.transcriber = None

    def load(self, payload: dict[str, object]) -> dict[str, object]:
        self.options = dict(payload.get("options", {}))
        self.model_path = str(payload.get("model_path") or self.options.get("model_path", ""))
        self.model_arch = str(self.options.get("model_arch", "smallStreaming"))
        self.ort_providers = str(self.options.get("ort_providers", "CPU"))
        self.support_prompt = bool(self.options.get("supports_prompt", False))
        if not Path(self.model_path).exists():
            raise RuntimeError(f"Missing path: {self.model_path}")

        try:
            module = importlib.import_module("moonshine_voice")
            transcriber_cls = getattr(module, "Transcriber")
        except ModuleNotFoundError as error:
            raise RuntimeError("Missing Python module: moonshine_voice") from error

        try:
            provider_list = [item.strip() for item in self.ort_providers.split(",") if item.strip()]
            if not provider_list:
                raise ValueError("No ONNX providers configured")
            self.transcriber = transcriber_cls(
                model_path=self.model_path,
                model_arch=self.model_arch,
                options={
                    "ort_providers": self.ort_providers,
                    "return_audio_data": False,
                },
            )
            provider_value = ",".join(provider_list)
            self.options["ort_providers"] = provider_value
        except Exception as error:
            raise RuntimeError(f"Failed to construct Moonshine Transcriber: {error}") from error

        self.ready = True
        return {
            "status": "loaded",
            "backend": "moonshine",
            "model_path": self.model_path,
            "model_arch": self.model_arch,
            "ort_providers": self.ort_providers,
        }

    def transcribe(self, payload: dict[str, object]) -> dict[str, object]:
        if not self.ready or self.transcriber is None:
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

        samples, sample_rate = read_wav_float32(audio_path)
        if not samples:
            return error_payload("Audio file is empty")

        try:
            result = self.transcriber.transcribe_without_streaming(samples, sample_rate, flags=0)  # type: ignore[attr-defined]
        except Exception as error:
            return error_payload(f"Moonshine transcribe failed: {error}")

        text = ""
        words = []
        segments = []
        if isinstance(result, str):
            text = result
        elif isinstance(result, dict):
            text = str(result.get("text", "") or result.get("result", ""))
            if isinstance(result.get("segments"), list):
                segments = result.get("segments", [])
            if isinstance(result.get("words"), list):
                words = result.get("words", [])
        else:
            text = str(result)

        return {
            "text": text,
            "segments": segments,
            "words": words,
            "metadata": {
                "backend": "moonshine",
                "model": self.model_arch,
                "model_path": self.model_path,
                "providers": self.ort_providers,
            },
        }

    def close(self) -> None:
        self.ready = False
        self.transcriber = None


def main() -> None:
    worker = MoonshineWorker()
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
