#!/usr/bin/env python3
from __future__ import annotations

import ctypes
import json
import struct
import wave
from pathlib import Path

from transducer_worker_utils import error_payload


PARAKEET_SAMPLE_RATE = 16000
PARAKEET_DEFAULT_LIBRARY = "/opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib"
PARAKEET_DEFAULT_GGML_LIBRARY = "/opt/homebrew/opt/ggml/lib/libggml.0.dylib"
PARAKEET_GGML_BACKEND_DIR = Path("/opt/homebrew/opt/ggml/libexec")
PARAKEET_SAMPLING_GREEDY = 0


class ParakeetContextParams(ctypes.Structure):
    _fields_ = [
        ("use_gpu", ctypes.c_bool),
        ("gpu_device", ctypes.c_int),
    ]


class ParakeetFullParams(ctypes.Structure):
    _fields_ = [
        ("strategy", ctypes.c_int),
        ("n_threads", ctypes.c_int),
        ("offset_ms", ctypes.c_int),
        ("duration_ms", ctypes.c_int),
        ("no_context", ctypes.c_bool),
        ("audio_ctx", ctypes.c_int),
        ("new_segment_callback", ctypes.c_void_p),
        ("new_segment_callback_user_data", ctypes.c_void_p),
        ("new_token_callback", ctypes.c_void_p),
        ("new_token_callback_user_data", ctypes.c_void_p),
        ("progress_callback", ctypes.c_void_p),
        ("progress_callback_user_data", ctypes.c_void_p),
        ("encoder_begin_callback", ctypes.c_void_p),
        ("encoder_begin_callback_user_data", ctypes.c_void_p),
        ("abort_callback", ctypes.c_void_p),
        ("abort_callback_user_data", ctypes.c_void_p),
    ]


class ParakeetTimings(ctypes.Structure):
    _fields_ = [
        ("sample_ms", ctypes.c_float),
        ("encode_ms", ctypes.c_float),
        ("decode_ms", ctypes.c_float),
    ]


def _as_bool(value: object, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return bool(value)
    return str(value).strip().lower() in {"1", "true", "yes", "on", "y"}


def _to_text(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _clean_text(value: str) -> str:
    return " ".join(part for part in (value or "").split() if part).strip()


def _read_wav_mono_16k_pcm16(audio_path: str) -> tuple[list[float], int]:
    with wave.open(audio_path, "rb") as handle:
        sample_rate = int(handle.getframerate())
        if handle.getnchannels() != 1:
            raise ValueError("Expected mono WAV input")
        if sample_rate != PARAKEET_SAMPLE_RATE:
            raise ValueError(f"Expected sample rate {PARAKEET_SAMPLE_RATE}, got {sample_rate}")
        if handle.getsampwidth() != 2:
            raise ValueError("Expected 16-bit PCM WAV input")
        if handle.getcomptype() not in {"NONE", "not compressed"}:
            raise ValueError("Expected uncompressed PCM WAV input")
        raw = handle.readframes(handle.getnframes())

    if not raw:
        return [], sample_rate

    samples = [value / 32768.0 for (value,) in struct.iter_unpack("<h", raw)]
    return [max(-1.0, min(1.0, sample)) for sample in samples], sample_rate


def _bind_library(lib: ctypes.CDLL) -> None:
    required = [
        "parakeet_init_from_file_with_params",
        "parakeet_free",
        "parakeet_free_state",
        "parakeet_full",
        "parakeet_full_with_state",
        "parakeet_reset_timings",
        "parakeet_get_timings",
        "parakeet_full_n_segments_from_state",
        "parakeet_full_get_segment_text_from_state",
        "parakeet_full_n_segments",
        "parakeet_full_get_segment_text",
    ]
    missing = [name for name in required if not hasattr(lib, name)]
    if missing:
        raise RuntimeError(f"libparakeet ABI is incomplete: missing symbols: {', '.join(missing)}")

    lib.parakeet_init_from_file_with_params.argtypes = [
        ctypes.c_char_p,
        ParakeetContextParams,
    ]
    lib.parakeet_init_from_file_with_params.restype = ctypes.c_void_p
    lib.parakeet_free.argtypes = [ctypes.c_void_p]
    lib.parakeet_free.restype = None
    lib.parakeet_free_state.argtypes = [ctypes.c_void_p]
    lib.parakeet_free_state.restype = None
    lib.parakeet_full.argtypes = [
        ctypes.c_void_p,
        ParakeetFullParams,
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_int,
    ]
    lib.parakeet_full.restype = ctypes.c_int
    lib.parakeet_full_with_state.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ParakeetFullParams,
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_int,
    ]
    lib.parakeet_full_with_state.restype = ctypes.c_int
    lib.parakeet_reset_timings.argtypes = [ctypes.c_void_p]
    lib.parakeet_reset_timings.restype = None
    lib.parakeet_get_timings.argtypes = [ctypes.c_void_p]
    lib.parakeet_get_timings.restype = ctypes.POINTER(ParakeetTimings)
    lib.parakeet_full_n_segments_from_state.argtypes = [ctypes.c_void_p]
    lib.parakeet_full_n_segments_from_state.restype = ctypes.c_int
    lib.parakeet_full_get_segment_text_from_state.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.parakeet_full_get_segment_text_from_state.restype = ctypes.c_char_p
    lib.parakeet_full_n_segments.argtypes = [ctypes.c_void_p]
    lib.parakeet_full_n_segments.restype = ctypes.c_int
    lib.parakeet_full_get_segment_text.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.parakeet_full_get_segment_text.restype = ctypes.c_char_p


def _bind_ggml_library(use_gpu: bool) -> ctypes.CDLL:
    try:
        libggml = ctypes.CDLL(PARAKEET_DEFAULT_GGML_LIBRARY)
    except OSError as error:
        raise RuntimeError(f"libggml library failed to load: {error}") from error
    if not hasattr(libggml, "ggml_backend_load"):
        raise RuntimeError("libggml ABI is incomplete: missing symbol ggml_backend_load")
    libggml.ggml_backend_load.argtypes = [ctypes.c_char_p]
    libggml.ggml_backend_load.restype = ctypes.c_void_p
    candidates = [
        PARAKEET_GGML_BACKEND_DIR / "libggml-blas.so",
        PARAKEET_GGML_BACKEND_DIR / "libggml-cpu-apple_m2_m3.so",
    ]
    if use_gpu:
        candidates.append(PARAKEET_GGML_BACKEND_DIR / "libggml-metal.so")
    missing = [str(path) for path in candidates if not path.exists()]
    if missing:
        raise RuntimeError(f"Missing ggml backend: {', '.join(missing)}")
    for path in candidates:
        if not libggml.ggml_backend_load(str(path).encode("utf-8")):
            raise RuntimeError(f"ggml backend failed to load: {path}")
    return libggml


class ParakeetLibWorker:
    def __init__(self) -> None:
        self.library = PARAKEET_DEFAULT_LIBRARY
        self.model_path = ""
        self.threads = 4
        self.use_gpu = True
        self.gpu_device = 0
        self.support_prompt = False
        self.support_language_override = False
        self.support_languages: list[str] = []
        self.ready = False
        self._context: int | None = None
        self._state: int | None = None
        self._lib: ctypes.CDLL | None = None
        self._ggml: ctypes.CDLL | None = None

    def _load_library(self, library_path: str) -> ctypes.CDLL:
        try:
            lib = ctypes.CDLL(library_path)
        except OSError as error:
            raise RuntimeError(f"libparakeet library failed to load: {error}") from error
        self._ggml = _bind_ggml_library(self.use_gpu)
        _bind_library(lib)
        return lib

    def load(self, payload: dict[str, object]) -> dict[str, object]:
        options = dict(payload.get("options", {}))
        self.close()

        self.library = str(options.get("library", self.library))
        self.model_path = str(payload.get("model_path") or options.get("model_path", ""))
        self.threads = int(options.get("threads", 4))
        self.use_gpu = _as_bool(options.get("use_gpu"), True)
        if "no_gpu" in options and _as_bool(options.get("no_gpu"), False):
            self.use_gpu = False
        self.gpu_device = int(options.get("gpu_device", 0))
        self.support_prompt = bool(options.get("supports_prompt", False))
        self.support_language_override = bool(options.get("supports_language_override", False))
        self.support_languages = [str(item) for item in options.get("supported_languages", [])]

        if self.library and not Path(self.library).exists():
            raise RuntimeError(f"Missing path: {self.library}")
        if self.model_path and not Path(self.model_path).exists():
            raise RuntimeError(f"Missing path: {self.model_path}")

        self._lib = self._load_library(self.library)
        context_params = ParakeetContextParams(
            use_gpu=self.use_gpu,
            gpu_device=self.gpu_device,
        )
        context = self._lib.parakeet_init_from_file_with_params(
            self.model_path.encode("utf-8"),
            context_params,
        )
        if not context:
            self.close()
            raise RuntimeError("libparakeet failed to allocate context")
        self._context = context
        self._state = None
        self.ready = True
        return {
            "status": "loaded",
            "backend": "libparakeet",
            "model_path": self.model_path,
            "model": str(payload.get("model", "")),
            "library": self.library,
        }

    def _validate_request(self, payload: dict[str, object]) -> str | None:
        language = str(payload.get("language") or "")
        if payload.get("prompt") and not self.support_prompt:
            return "Prompt is not supported by this backend"
        normalized_language = language.strip().lower()
        if normalized_language and normalized_language not in {"", "auto"}:
            if self.support_languages and normalized_language not in [item.lower() for item in self.support_languages]:
                return f"Unsupported language for this backend: {language}"
            if not self.support_language_override:
                return f"Language override is not supported: {language}"
        return None

    def _read_segments(self) -> list[str]:
        if not self._lib or not self._context:
            return []
        count = int(self._lib.parakeet_full_n_segments(self._context))
        segments: list[str] = []
        for index in range(count):
            raw_text = _to_text(self._lib.parakeet_full_get_segment_text(self._context, index))
            if raw_text.strip():
                segments.append(raw_text.strip())
        return segments

    def _read_timings(self) -> tuple[float, float, float]:
        if not self._lib or not self._context:
            return 0.0, 0.0, 0.0
        timings = self._lib.parakeet_get_timings(self._context)
        if not timings:
            return 0.0, 0.0, 0.0
        return (
            float(timings.contents.sample_ms),
            float(timings.contents.encode_ms),
            float(timings.contents.decode_ms),
        )

    def transcribe(self, payload: dict[str, object]) -> dict[str, object]:
        if not self.ready:
            raise RuntimeError("Worker is not loaded")
        if not self._lib or not self._context:
            return error_payload("libparakeet runtime is unavailable")

        reason = self._validate_request(payload)
        if reason:
            return error_payload(reason, backend="libparakeet")

        audio_path = str(payload.get("audio_path") or payload.get("audio", ""))
        if not audio_path:
            return error_payload("Missing audio path")
        if not Path(audio_path).exists():
            return error_payload(f"Missing path: {audio_path}")
        try:
            samples, sample_rate = _read_wav_mono_16k_pcm16(audio_path)
        except ValueError as error:
            return error_payload(str(error))
        if not samples:
            return error_payload("No PCM samples found in audio path")
        if sample_rate != PARAKEET_SAMPLE_RATE:
            return error_payload(f"Expected {PARAKEET_SAMPLE_RATE}Hz input, got {sample_rate}Hz")

        self._lib.parakeet_reset_timings(self._context)
        params = ParakeetFullParams(
            strategy=PARAKEET_SAMPLING_GREEDY,
            n_threads=self.threads,
            offset_ms=0,
            duration_ms=0,
            no_context=True,
            audio_ctx=0,
            new_segment_callback=None,
            new_segment_callback_user_data=None,
            new_token_callback=None,
            new_token_callback_user_data=None,
            progress_callback=None,
            progress_callback_user_data=None,
            encoder_begin_callback=None,
            encoder_begin_callback_user_data=None,
            abort_callback=None,
            abort_callback_user_data=None,
        )
        sample_buffer = (ctypes.c_float * len(samples))(*samples)
        returncode = self._lib.parakeet_full(
            self._context,
            params,
            sample_buffer,
            len(samples),
        )
        if returncode != 0:
            return error_payload(
                f"libparakeet full transcribe failed with code {returncode}",
                returncode=returncode,
            )

        segments = self._read_segments()
        text = _clean_text(" ".join(segments))
        sample_ms, encode_ms, decode_ms = self._read_timings()
        backend_ms = sample_ms + encode_ms + decode_ms

        return {
            "text": text,
            "segments": [{"text": segment} for segment in segments],
            "words": [],
            "backend_ms": backend_ms,
            "preprocess_ms": sample_ms,
            "encode_ms": encode_ms,
            "decode_ms": decode_ms,
            "metadata": {
                "backend": "libparakeet",
                "sample_ms": sample_ms,
                "encode_ms": encode_ms,
                "decode_ms": decode_ms,
                "thread_count": self.threads,
                "use_gpu": self.use_gpu,
                "sample_rate": sample_rate,
                "n_samples": len(samples),
                "library": self.library,
            },
        }

    def close(self) -> None:
        if self._lib is not None:
            if self._state is not None:
                try:
                    self._lib.parakeet_free_state(self._state)
                except Exception:
                    pass
            if self._context is not None:
                try:
                    self._lib.parakeet_free(self._context)
                except Exception:
                    pass
        self._context = None
        self._state = None
        self._lib = None
        self.ready = False


def main() -> None:
    worker = ParakeetLibWorker()
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
