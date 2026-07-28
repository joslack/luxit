#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def _emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\n")
    sys.stdout.flush()


def _coerce_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _normalize_seconds(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _to_ms(seconds: Any) -> int | None:
    normalized = _normalize_seconds(seconds)
    if normalized is None:
        return None
    return int(round(normalized * 1000.0))


def _normalize_segments(values: Any) -> list[dict[str, Any]]:
    if not isinstance(values, list):
        return []

    normalized: list[dict[str, Any]] = []
    for item in values:
        if isinstance(item, dict):
            start = _to_ms(item.get("start"))
            end = _to_ms(item.get("end"))
            text = str(item.get("text", "")).strip()
            if text or start is not None or end is not None:
                normalized.append({"start_ms": start, "end_ms": end, "text": text})
            continue
        if hasattr(item, "start") and hasattr(item, "end") and hasattr(item, "text"):
            start = _to_ms(getattr(item, "start"))
            end = _to_ms(getattr(item, "end"))
            text = str(getattr(item, "text", "")).strip()
            if text or start is not None or end is not None:
                normalized.append({"start_ms": start, "end_ms": end, "text": text})
    return normalized


@dataclass
class WorkerState:
    backend_id: str | None = None
    engine: str | None = None
    model_id: str | None = None
    model_path: str | None = None
    model: Any = None
    language_mode: str = "multilingual"
    loaded_at_ms: float | None = None
    options: dict[str, Any] | None = None

    def reset(self) -> None:
        self.backend_id = None
        self.engine = None
        self.model_id = None
        self.model_path = None
        self.model = None
        self.loaded_at_ms = None
        self.language_mode = "multilingual"
        self.options = None


class _MockModel:
    def generate(self, audio_path: str, **kwargs: Any) -> dict[str, Any]:
        return {
            "text": f"mock transcription for {Path(audio_path).name}",
            "segments": [
                {
                    "start": 0.0,
                    "end": 0.8,
                    "text": "mock transcription for " + Path(audio_path).name,
                }
            ],
        }


state = WorkerState()


def _load_model(request: dict[str, Any]) -> dict[str, Any]:
    model_id = str(request.get("model", "")).strip()
    model_path = str(request.get("model_path", "")).strip()
    options = request.get("options", {}) or {}

    if not model_id:
        return {"error": "missing model"}
    if not _coerce_bool(os.environ.get("STTBENCH_MOCK_MLX_WORKER")):
        if not model_path:
            return {"error": "missing model_path"}
        if not Path(model_path).exists():
            return {"error": f"model artifact missing: {model_path}"}

        try:
            from mlx_audio.stt.utils import load_model
        except Exception as error:
            return {"error": f"mlx_audio dependency missing: {error}"}

    engine = str(options.get("engine", "mlx_audio"))
    if engine != "mlx_audio":
        return {"error": f"unsupported MLX engine: {engine}"}

    start = time.perf_counter()
    state.engine = engine
    state.model_id = model_id
    state.model_path = model_path
    state.backend_id = str(request.get("backend_id", "mlx-whisper"))
    state.language_mode = str(options.get("language_mode", "multilingual"))
    state.options = dict(options)

    if _coerce_bool(os.environ.get("STTBENCH_MOCK_MLX_WORKER")):
        state.model = _MockModel()
    else:
        try:
            from mlx_audio.stt.utils import load_model

            # Resolve the checked-in manifest to the prepared local snapshot so
            # timed runs never include a network lookup or an accidental model
            # revision change.
            state.model = load_model(model_path)
        except Exception as error:
            return {"error": f"failed to load MLX model {model_id}: {error}"}

    state.loaded_at_ms = (time.perf_counter() - start) * 1000.0
    return {
        "backend_id": state.backend_id,
        "model_id": model_id,
        "model_path": model_path,
        "load_ms": state.loaded_at_ms,
    }


def _infer_language(language: str | None) -> tuple[str | None, list[str]]:
    if not language:
        return None, ["language detection requested; distil variants do not support detection in benchmark profile"]
    normalized = str(language).strip().lower()
    if normalized in {"", "en", "en-us", "en-gb", "eng"}:
        return "en", []
    return None, ["language mismatch: this MLX variant is English-only"]


def _transcribe(request: dict[str, Any]) -> dict[str, Any]:
    if not state.model:
        return {"error": "no model loaded; call load first"}

    audio = request.get("audio_path")
    if not audio:
        return {"error": "missing audio_path"}
    if not Path(audio).is_file():
        return {"error": f"audio file not found: {audio}"}

    options = request.get("options", {}) or {}
    supports_word_timestamps = _coerce_bool(options.get("supports_word_timestamps", False))
    request_word_timestamps = _coerce_bool(request.get("word_timestamps"))
    if request_word_timestamps and not supports_word_timestamps:
        return {"error": "word timestamps requested but unsupported"}

    language = request.get("language")
    if state.language_mode == "en-only":
        effective, warnings = _infer_language(language)
        if effective is None:
            return {
                "error": "language request rejected; Distil-Whisper variant is English-only",
                "warnings": warnings,
            }
        language = effective
    else:
        language = (language or None)
        warnings = []

    prompt = request.get("prompt")
    model_kwargs = {
        "language": language,
        "task": "transcribe",
        "initial_prompt": prompt,
        "condition_on_previous_text": False,
        "temperature": _coerce_float(options.get("temperature"), 0.0),
        "best_of": _coerce_int(options.get("best_of"), 1),
        "word_timestamps": request_word_timestamps,
        "return_timestamps": request_word_timestamps,
    }
    beam_size = _coerce_int(options.get("beam_size"), 1)
    if beam_size > 1:
        model_kwargs["beam_size"] = beam_size

    if _coerce_bool(os.environ.get("STTBENCH_MOCK_MLX_WORKER")):
        start = time.perf_counter()
        result = state.model.generate(audio, **model_kwargs)
        inference_ms = (time.perf_counter() - start) * 1000.0
    else:
        start = time.perf_counter()
        result = state.model.generate(audio, **model_kwargs)
        inference_ms = (time.perf_counter() - start) * 1000.0

    text = ""
    segments: list[dict[str, Any]] = []

    if isinstance(result, dict):
        text = str(result.get("text", "")).strip()
        segments = _normalize_segments(result.get("segments"))
        if request_word_timestamps and segments:
            words: list[dict[str, Any]] = []
            for item in result.get("segments") or []:
                if isinstance(item, dict) and isinstance(item.get("words"), list):
                    words.extend(_normalize_segments(item.get("words")))
            words_payload = words
        else:
            words_payload = []
    elif hasattr(result, "text"):
        text = str(getattr(result, "text", "")).strip()
        raw_segments = getattr(result, "segments", [])
        segments = _normalize_segments(raw_segments)
        words_payload = []
    else:
        text = str(result) if result is not None else ""
        words_payload = []

    return {
        "backend_id": state.backend_id or "mlx-whisper",
        "text": text,
        "segments": segments,
        "words": words_payload,
        "backend_ms": inference_ms,
        "warnings": warnings,
        "metadata": {
            "model_id": state.model_id,
            "model_path": state.model_path,
            "model_mode": state.language_mode,
            "engine": state.engine,
        },
    }


def _coerce_float(value: Any, default: float) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _coerce_int(value: Any, default: int) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _dispatch(request: dict[str, Any]) -> dict[str, Any]:
    request_type = str(request.get("type", "")).strip()
    if request_type == "list_models":
        return {
            "backend_id": str(request.get("backend_id", "mlx-whisper")),
            "models": [
                {
                    "logical_name": "large-v3-turbo",
                    "artifact": "mlx-community/whisper-large-v3-turbo-asr-fp16",
                    "revision": "local",
                },
                {
                    "logical_name": "distil-large-v3",
                    "artifact": "mlx-community/distil-whisper-large-v3",
                    "revision": "local",
                },
            ],
        }
    if request_type in {"initialize", "load"}:
        return _load_model(request)
    if request_type == "transcribe":
        return _transcribe(request)
    if request_type == "unload":
        state.reset()
        return {"status": "unloaded"}
    if request_type == "shutdown":
        state.reset()
        return {"status": "shutdown"}
    return {"error": f"unknown request type: {request_type}"}


def main() -> int:
    try:
        for raw in iter(sys.stdin.readline, ""):
            raw = raw.strip()
            if not raw:
                continue
            payload = json.loads(raw)
            response = _dispatch(payload)
            _emit(response)
            if payload.get("type") == "shutdown":
                return 0
    except Exception as error:
        _emit({"error": str(error), "backend_id": state.backend_id or "mlx-whisper"})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
