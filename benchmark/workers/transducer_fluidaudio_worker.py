#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import time
from pathlib import Path

from transducer_worker_utils import error_payload, run_command


def _load_supports(payload: dict[str, object], key: str, default: bool = False) -> bool:
    return bool(payload.get(key, default))


def _list_as_lines(value: object) -> list[str]:
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


class FluidAudioWorker:
    def __init__(self) -> None:
        self.cli = "fluidaudiocli"
        self.model_version = ""
        self.model_path = ""
        self.supported_languages: list[str] = []
        self.support_language_override = False
        self.support_prompt = False
        self.support_word_timestamps = False
        self.ready = False
        self.options: dict[str, object] = {}
        self.load_latency_ms = 0.0

    def load(self, payload: dict[str, object]) -> dict[str, object]:
        self.options = dict(payload.get("options", {}))
        self.cli = str(self.options.get("cli", self.cli))
        self.model_version = str(payload.get("model", "") or self.options.get("model_version", ""))
        self.model_path = str(payload.get("model_path", ""))
        self.supported_languages = [str(item) for item in self.options.get("supported_languages", [])]
        self.support_language_override = _load_supports(self.options, "supports_language_override")
        self.support_prompt = _load_supports(self.options, "supports_prompt")
        self.support_word_timestamps = _load_supports(self.options, "supports_word_timestamps")
        if shutil.which(self.cli) is None:
            raise RuntimeError(f"Missing command: {self.cli}")
        if self.model_path and not Path(self.model_path).exists():
            raise RuntimeError(f"Missing path: {self.model_path}")
        output_mode = str(self.options.get("output_mode", "batch"))
        self.ready = True
        started = time.perf_counter()
        return {
            "status": "loaded",
            "backend": "fluidaudio",
            "mode": output_mode,
            "model_version": self.model_version,
            "load_ms": (time.perf_counter() - started) * 1000.0 + self.load_latency_ms,
        }

    def _validate_request(self, payload: dict[str, object]) -> str | None:
        language = str(payload.get("language") or "")
        if language and not self.support_language_override and language.lower() not in {"", "auto", "en"}:
            return f"Language override is not supported: {language}"
        if language and self.supported_languages and language not in self.supported_languages:
            return f"Unsupported language for this model: {language}"
        if payload.get("prompt") and not self.support_prompt:
            return "Prompt is not supported by this backend"
        return None

    def transcribe(self, payload: dict[str, object]) -> dict[str, object]:
        if not self.ready:
            raise RuntimeError("Worker is not loaded")
        reason = self._validate_request(payload)
        if reason:
            return error_payload(reason, backend="fluidaudio", model_version=self.model_version)

        audio_path = str(payload.get("audio_path") or payload.get("audio", ""))
        if not audio_path:
            return error_payload("Missing audio path")
        if not Path(audio_path).exists():
            return error_payload(f"Missing path: {audio_path}")

        cmd = [
            self.cli,
            "transcribe",
            audio_path,
            "--model-version",
            self.model_version,
        ]
        extra_args = _list_as_lines(self.options.get("cli_args"))
        if self.options.get("streaming_variant_ms"):
            extra_args.extend(["--streaming-variant-ms", str(self.options["streaming_variant_ms"])])
        if self.options.get("output_json", False):
            extra_args.append("--output-json")
        if extra_args:
            cmd.extend(extra_args)

        if self.options.get("supports_word_timestamps") is False:
            pass
        returncode, _text, output = run_command(cmd, float(self.options.get("timeout_seconds", 600)))
        parsed = json.loads(output)
        if returncode != 0:
            return error_payload(parsed.get("metadata", {}).get("stderr", "FluidAudio CLI failed"), backend="fluidaudio", model_version=self.model_version, returncode=returncode)

        parsed["metadata"] = parsed.get("metadata", {})
        parsed["metadata"]["backend"] = "fluidaudio"
        parsed["metadata"]["mode"] = self.options.get("output_mode", "batch")
        parsed["metadata"]["model_version"] = self.model_version
        return parsed

    def close(self) -> None:
        self.ready = False


def _main() -> None:
    worker = FluidAudioWorker()
    while True:
        line = input().strip()
        if not line:
            continue
        payload = json.loads(line)
        type_ = payload.get("type")
        if type_ == "load":
            response = worker.load(payload)
        elif type_ == "transcribe":
            response = worker.transcribe(payload)
        elif type_ == "shutdown":
            response = {"status": "shutdown"}
            worker.close()
            print(json.dumps(response, separators=(",", ":")))
            break
        else:
            response = error_payload(f"Unsupported message type: {type_}")
        print(json.dumps(response, separators=(",", ":")))


if __name__ == "__main__":
    _main()
