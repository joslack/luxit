from __future__ import annotations

import importlib
import json
import sys
import time
from typing import Any


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    if isinstance(value, (int, float)):
        return value != 0
    text = str(value).strip().lower()
    return text in {"1", "true", "yes", "y", "on"}


def _normalize_language(value: Any) -> str:
    if not value:
        return ""
    return str(value).strip().lower().replace("_", "-")


def _normalize_language_token(language: str) -> str:
    language = _normalize_language(language)
    if not language:
        return ""
    if language in {"auto", "und", "unknown", "any"}:
        return language
    return language.split("-", maxsplit=1)[0]


def validate_request(profile: dict[str, Any], request: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    supported_languages = [
        _normalize_language_token(item) for item in profile.get("supported_languages", [])
    ]
    if supported_languages:
        requested_language = _normalize_language_token(request.get("language", ""))
        if requested_language and requested_language not in supported_languages:
            errors.append(f"Unsupported language '{request.get('language')}'")

    if request.get("prompt") and not profile.get("supports_prompt", False):
        errors.append("Prompt/vocabulary context is not supported by this backend")

    if _as_bool(request.get("word_timestamps")) and not profile.get(
        "supports_word_timestamps", False
    ):
        errors.append("Word timestamps are not supported by this backend")

    timestamp_mode = _normalize_language(request.get("timestamps"))
    if timestamp_mode in {"word", "words"} and not profile.get(
        "supports_word_timestamps", False
    ):
        errors.append("Word timestamps are not supported by this backend")
    if timestamp_mode in {"segment", "segments", "sentence", "sentences"} and not profile.get(
        "supports_segment_timestamps", False
    ):
        errors.append("Segment timestamps are not supported by this backend")

    if _as_bool(request.get("streaming")) and not profile.get("supports_streaming", False):
        errors.append("Streaming is not supported by this backend")

    if _as_bool(request.get("diarization")) and not profile.get(
        "supports_diarization", False
    ):
        errors.append("Diarization is not supported by this backend")

    translation_requested = (
        _as_bool(request.get("translation"))
        or _as_bool(request.get("translate"))
        or request.get("target_language") is not None
        or request.get("target_lang") is not None
    )
    if translation_requested and not profile.get("supports_translation", False):
        errors.append("Translation is not supported by this backend")

    return errors


def _safe_invoke(callable_obj, audio_path: str, call_kwargs: dict[str, Any]):
    attempts = [
        lambda: callable_obj(audio_path, **call_kwargs),
        lambda: callable_obj(audio=audio_path, **call_kwargs),
        lambda: callable_obj(audio_path=audio_path, **call_kwargs),
        lambda: callable_obj(path=audio_path, **call_kwargs),
        lambda: callable_obj(str(audio_path), **call_kwargs),
    ]
    for attempt in attempts:
        try:
            return attempt()
        except TypeError:
            continue
    # As a last-resort fallback, try the bare payload with no kwargs.
    if call_kwargs:
        return callable_obj(audio_path)
    return callable_obj()


def _normalize_result(raw: Any) -> tuple[str, list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    if isinstance(raw, str):
        return raw.strip(), [], [], {}
    if isinstance(raw, dict):
        text = str(raw.get("text", raw.get("transcript", raw.get("result", "")))).strip()
        return (
            text,
            list(raw.get("segments", [])),
            list(raw.get("words", [])),
            dict(raw.get("metadata", {})),
        )
    if isinstance(raw, (list, tuple)) or (
        hasattr(raw, "__iter__") and not isinstance(raw, (dict, str, bytes))
    ):
        pieces: list[str] = []
        segments: list[dict[str, Any]] = []
        words: list[dict[str, Any]] = []
        metadata: dict[str, Any] = {}
        for piece in raw:
            if isinstance(piece, str):
                pieces.append(piece)
            elif isinstance(piece, dict):
                segments.append(piece)
                text_piece = piece.get("text")
                if text_piece:
                    pieces.append(str(text_piece))
                piece_words = piece.get("words")
                if isinstance(piece_words, list):
                    words.extend(piece_words)
                piece_metadata = piece.get("metadata")
                if isinstance(piece_metadata, dict):
                    metadata.update(piece_metadata)
            elif piece is not None:
                pieces.append(str(piece))
        return ("".join(pieces).strip(), segments, words, metadata)
    return "", [], [], {"type": f"unsupported-result:{type(raw)!r}"}


def _run_qwen3_mlx(
    state: dict[str, Any], request: dict[str, Any]
) -> tuple[str, float, list[dict[str, Any]], list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    session = state["session"]
    profile = state["profile"]
    call_kwargs: dict[str, Any] = {}
    language = request.get("language")
    if language:
        call_kwargs["language"] = language
    prompt = request.get("prompt")
    if prompt:
        call_kwargs["context"] = prompt
    if _as_bool(request.get("word_timestamps")):
        if not profile.get("alignment_model_path") and not profile.get("aligner_model"):
            raise RuntimeError("Word timestamps requested, but no aligner model is configured")
        # Qwen aligner behavior is model/version dependent; request both key names.
        call_kwargs["timestamps"] = True
        call_kwargs["return_timestamps"] = True
    if _as_bool(request.get("streaming")):
        if not hasattr(session, "init_streaming") or not hasattr(session, "feed_audio"):
            raise RuntimeError("Streaming requested but not supported by this mlx-qwen3-asr runtime")
        raise RuntimeError("Streaming is not implemented in the current frontier worker fallback path")
    started = time.perf_counter()
    raw = _safe_invoke(session.transcribe, request["audio_path"], call_kwargs)
    backend_ms = (time.perf_counter() - started) * 1000.0
    text, segments, words, metadata = _normalize_result(raw)
    return text, backend_ms, segments, words, metadata, {}


def _run_mlx_audio(
    state: dict[str, Any], request: dict[str, Any]
) -> tuple[str, float, list[dict[str, Any]], list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    model = state["model"]
    profile = state["profile"]
    call_kwargs: dict[str, Any] = {}
    language = request.get("language")
    if language:
        call_kwargs["language"] = language
    prompt = request.get("prompt")
    if prompt and profile.get("supports_prompt"):
        call_kwargs["prompt"] = prompt
    if request.get("source_language"):
        call_kwargs["source_lang"] = request["source_language"]
    if request.get("target_language"):
        call_kwargs["target_lang"] = request["target_language"]
    if request.get("target_lang"):
        call_kwargs["target_lang"] = request["target_lang"]
    if _as_bool(request.get("word_timestamps")):
        # These backends advertise no stable word timestamps unless explicitly stated.
        raise RuntimeError("Word timestamps requested but this backend profile does not support them")
    if _as_bool(request.get("streaming")):
        # Stream mode is only supported for models that opt-in via profile.
        if not profile.get("supports_streaming", False):
            raise RuntimeError("Streaming requested but not supported by this backend profile")
        call_kwargs["stream"] = True
        call_kwargs["transcription_delay_ms"] = int(
            request.get("streaming_delay_ms", profile.get("streaming_delay_ms", 480))
        )
    started = time.perf_counter()
    raw = _safe_invoke(model.generate, request["audio_path"], call_kwargs)
    backend_ms = (time.perf_counter() - started) * 1000.0
    text, segments, words, metadata = _normalize_result(raw)
    if request.get("stream") and isinstance(raw, dict):
        metadata.setdefault("partial_events", raw.get("partial_events", []))
    return text, backend_ms, segments, words, metadata, {}


def _load_profile(message: dict[str, Any]) -> dict[str, Any]:
    options = dict(message.get("options", {}))
    runtime = options.get("runtime")
    if not runtime:
        raise RuntimeError("Backend load payload does not include runtime")
    model = str(message.get("model") or options.get("model", "")).strip()
    model_path = str(message.get("model_path") or options.get("model_path", "")).strip()
    if not model and not model_path:
        raise RuntimeError("Backend load payload is missing model/model_path")

    if runtime in {"qwen3_mlx"}:
        module = importlib.import_module("mlx_qwen3_asr")
        session_cls = getattr(module, "Session", None)
        if session_cls is None:
            raise RuntimeError("mlx_qwen3_asr.Session is unavailable")
        # Most variants expose model-only constructors; this fallback keeps the worker stable if
        # the local package API changes.
        try:
            session = session_cls(model=model or model_path)
        except TypeError:
            session = session_cls(model_path=model_path, model=model)
        return {
            "runtime": runtime,
            "profile": options,
            "session": session,
            "model": model,
            "model_path": model_path,
        }

    if runtime in {"mlx_audio", "mlx_audio_canary"}:
        module = importlib.import_module("mlx_audio.stt.utils")
        load = getattr(module, "load", None)
        if not callable(load):
            raise RuntimeError("mlx_audio.stt.utils.load is unavailable")
        model_obj = load(model or model_path)
        return {
            "runtime": runtime,
            "profile": options,
            "model": model_obj,
            "model_path": model_path,
        }
    raise RuntimeError(f"Unknown runtime '{runtime}'")


def _transcribe(message: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    request = message
    profile = state["profile"]
    errors = validate_request(profile, request)
    if errors:
        return {"error": "; ".join(errors)}

    runtime = state["runtime"]
    if runtime == "qwen3_mlx":
        text, backend_ms, segments, words, metadata, extra = _run_qwen3_mlx(state, request)
    elif runtime in {"mlx_audio", "mlx_audio_canary"}:
        text, backend_ms, segments, words, metadata, extra = _run_mlx_audio(state, request)
    else:
        return {"error": f"Unhandled runtime '{runtime}'"}

    metadata.update(extra)
    result: dict[str, Any] = {
        "text": text,
        "backend_ms": backend_ms,
        "load_ms": None,
        "preprocess_ms": None,
        "decode_ms": None,
        "segments": segments,
        "words": words,
        "metadata": metadata,
    }
    if "word_timestamps" in request:
        result["metadata"]["requested_word_timestamps"] = _as_bool(
            request["word_timestamps"]
        )
    return result


def _handle_loop() -> None:
    state: dict[str, Any] = {}
    loaded = False
    while True:
        raw_line = sys.stdin.readline()
        if not raw_line:
            break
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            message = json.loads(raw_line)
        except json.JSONDecodeError as error:
            print(json.dumps({"error": f"Invalid JSON: {error}"}), flush=True)
            continue

        message_type = message.get("type")
        if message_type == "load":
            started = time.perf_counter()
            try:
                state = _load_profile(message)
                state["load_ms"] = (time.perf_counter() - started) * 1000.0
                loaded = True
                print(json.dumps({"ok": True, "load_ms": state["load_ms"]}), flush=True)
            except Exception as error:
                loaded = False
                print(json.dumps({"error": str(error)}), flush=True)
            continue

        if message_type == "shutdown":
            print(json.dumps({"ok": True}), flush=True)
            return

        if message_type != "transcribe":
            print(json.dumps({"error": f"Unknown message type '{message_type}'"}), flush=True)
            continue

        if not loaded:
            print(
                json.dumps({"error": "Worker is not loaded; send a load message first"}),
                flush=True,
            )
            continue
        try:
            payload = _transcribe(message, state)
            payload["load_ms"] = state.get("load_ms")
            print(json.dumps(payload), flush=True)
        except Exception as error:
            print(json.dumps({"error": str(error), "metadata": {"backend": state.get("model")}}), flush=True)


def main() -> None:
    _handle_loop()


if __name__ == "__main__":
    main()
